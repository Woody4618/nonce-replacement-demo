#!/usr/bin/env bash
# Programmatic Signer demo (Anza, devnet).
# Cold key signs offline, hot relayer pays and submits. No durable nonce involved.
#
# Prereqs:
#   solana config set -ud                                  # devnet
#   cargo install --locked --git https://github.com/solana-program/ed25519-programmatic-signer clients/cli
#     (or clone + `cargo install --locked --path clients/cli`)
#   npm install                                            # @solana/kit for to-v1.mjs
#   Configured Solana CLI keypair funded with devnet SOL   # acts as the hot relayer / fee payer
set -euo pipefail

step() { printf '\n\033[1;36m# %s\033[0m\n' "$*"; }
run()  { printf '\033[2m$ %s\033[0m\n' "$*" >&2; "$@"; }
json() { node -pe "JSON.parse(require('fs').readFileSync(0))$1"; }

RECIPIENT=${RECIPIENT:-$(solana address)}      # where the PDA sends SOL (default: relayer)
AMOUNT=${AMOUNT:-0.001}

step "1. Create the cold authority key (air-gapped in real life)"
[ -f authority.json ] || run solana-keygen new --no-bip39-passphrase --silent --outfile authority.json
AUTHORITY=$(solana-keygen pubkey authority.json)
echo "AUTHORITY=$AUTHORITY"

step "2. Derive the signer PDA. No account to create, no setup."
PDA=$(run spl-programmatic-signer address "$AUTHORITY")
echo "PDA=$PDA"

step "3. Fund the PDA. It is a plain System-owned account, just like a wallet."
run solana transfer "$PDA" 0.05 --allow-unfunded-recipient >/dev/null
run solana balance "$PDA"

step "4. Create an SPL nonce account for replay protection (relayer pays)"
NONCE_ACCOUNT=$(run spl-programmatic-signer nonce create --cold-authority "$AUTHORITY" --output json | json .nonceAccount)
echo "NONCE_ACCOUNT=$NONCE_ACCOUNT"

step "5. Read the current nonce value"
NONCE_VALUE=$(run spl-programmatic-signer nonce show "$NONCE_ACCOUNT" --output json | json .nonce)
echo "NONCE_VALUE=$NONCE_VALUE"

step "6. Build the execution message with the normal Solana CLI (PDA is the 'from')"
LEGACY_MESSAGE=$(run solana transfer "$RECIPIENT" "$AMOUNT" \
  --from "$PDA" --fee-payer "$PDA" --blockhash "$NONCE_VALUE" \
  --sign-only --dump-transaction-message --allow-unfunded-recipient --output json | json .message)
# The executor only takes v1 messages; the Solana CLI still dumps legacy ones.
EXECUTION_MESSAGE=$(node to-v1.mjs "$LEGACY_MESSAGE")
echo "EXECUTION_MESSAGE=$EXECUTION_MESSAGE"

step "7. Simulate: see what the action does before anyone signs"
run spl-programmatic-signer transaction simulate "$EXECUTION_MESSAGE" "$NONCE_ACCOUNT" \
  --change-for-authority "$AUTHORITY"

step "8. Sign OFFLINE with the cold key. Nothing is sent. No blockhash, no expiry."
run spl-programmatic-signer transaction sign \
  --execution-message "$EXECUTION_MESSAGE" \
  --nonce-account "$NONCE_ACCOUNT" \
  --nonce-hash "$NONCE_VALUE" \
  --nonce-authority "$PDA" \
  --authority "$AUTHORITY" \
  --signer authority.json \
  --quiet --yes --output json > authorization.sign.json
SIGNATURE=$(json '[0].signature' < authorization.sign.json)
AUTHORIZATION_MESSAGE=$(json '[0].authorization_message' < authorization.sign.json)
NEXT_NONCE=$(json '[0].next_nonce' < authorization.sign.json)
echo "SIGNATURE=$SIGNATURE"
echo "NEXT_NONCE=$NEXT_NONCE   (known before execution: chains of messages can be pre-signed)"

step "9. Relay: any hot wallet submits and pays. Cold key holds no SOL for fees."
run spl-programmatic-signer transaction submit \
  --authorization-message "$AUTHORIZATION_MESSAGE" \
  --signer "$AUTHORITY=$SIGNATURE" \
  --yes

step "10. Nonce advanced to the predicted value, PDA paid the recipient"
run spl-programmatic-signer nonce show "$NONCE_ACCOUNT"
run solana balance "$PDA"

step "11. Replay the same authorization: rejected"
if spl-programmatic-signer transaction submit \
  --authorization-message "$AUTHORIZATION_MESSAGE" \
  --signer "$AUTHORITY=$SIGNATURE" --yes 2>replay.err; then
  echo "UNEXPECTED: replay succeeded"; exit 1
else
  cat replay.err; rm -f replay.err
fi
