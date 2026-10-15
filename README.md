# Programmatic Signer demo

Shows the durable-nonce replacement from Anza in action on devnet: a cold key signs an
authorization offline, a hot relayer submits and pays, the onchain nonce advances, and a
replay is rejected.

Background: [guide.md](guide.md) and the
[Anza docs](https://www.solana-program.com/docs/programmatic-signer/usage).

## Setup

```sh
solana config set -ud                       # devnet, configured keypair = hot relayer
solana airdrop 1                            # if the relayer needs SOL

git clone https://github.com/solana-program/ed25519-programmatic-signer.git
cargo install --locked --path ed25519-programmatic-signer/clients/cli
spl-programmatic-signer --help

npm install                                 # @solana/kit, used by to-v1.mjs
```

## Run

```sh
./demo.sh
```

Optional env: `RECIPIENT=<address> AMOUNT=0.001 ./demo.sh`.

## The commands, one by one

```sh
# cold key (never touches the network)
solana-keygen new --no-bip39-passphrase --outfile authority.json
AUTHORITY=$(solana-keygen pubkey authority.json)

# signer PDA: derived, nothing to initialize
PDA=$(spl-programmatic-signer address "$AUTHORITY")
solana transfer "$PDA" 0.05 --allow-unfunded-recipient

# replay protection: one SPL nonce account per in-flight message
NONCE_ACCOUNT=$(spl-programmatic-signer nonce create --cold-authority "$AUTHORITY" --output json | jq -r .nonceAccount)
NONCE_VALUE=$(spl-programmatic-signer nonce show "$NONCE_ACCOUNT" --output json | jq -r .nonce)

# the action, built with the normal Solana CLI, then re-encoded as v1
LEGACY=$(solana transfer <RECIPIENT> 0.001 --from "$PDA" --fee-payer "$PDA" \
  --blockhash "$NONCE_VALUE" --sign-only --dump-transaction-message \
  --allow-unfunded-recipient --output json | jq -r .message)
EXECUTION_MESSAGE=$(node to-v1.mjs "$LEGACY")

# preview
spl-programmatic-signer transaction simulate "$EXECUTION_MESSAGE" "$NONCE_ACCOUNT" \
  --change-for-authority "$AUTHORITY"

# sign offline
spl-programmatic-signer transaction sign \
  --execution-message "$EXECUTION_MESSAGE" \
  --nonce-account "$NONCE_ACCOUNT" --nonce-hash "$NONCE_VALUE" --nonce-authority "$PDA" \
  --authority "$AUTHORITY" --signer authority.json --output json > authorization.sign.json

# relay with any funded hot wallet (the configured keypair, or --fee-payer relayer.json)
spl-programmatic-signer transaction submit \
  --authorization-message "$(jq -r '.[0].authorization_message' authorization.sign.json)" \
  --signer "$AUTHORITY=$(jq -r '.[0].signature' authorization.sign.json)"

# nonce moved to the value `transaction sign` predicted; a second submit is rejected
spl-programmatic-signer nonce show "$NONCE_ACCOUNT"
```

## Two things the docs page does not say yet (as of 2026-10-07)

- The sign flag is `--execution-message`, not `--inner-message`.
- The executor only accepts **v1** execution messages. `solana ... --dump-transaction-message`
  (Agave CLI 4.1 to 4.3) still emits a legacy message, so `to-v1.mjs` re-encodes it with
  `@solana/kit` 8. `transaction simulate` and `transaction submit` already exist in the CLI even
  though the docs mark them "coming soon".
