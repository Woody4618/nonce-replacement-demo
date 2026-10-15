#!/usr/bin/env node
// Re-encodes a legacy message from `solana <cmd> --sign-only --dump-transaction-message`
// as a v1 message. The executor program only accepts v1 execution messages, and the
// Solana CLI (4.x) still dumps legacy ones.
//
// Usage:  node to-v1.mjs <base64-legacy-message>
//    or:  echo <base64> | node to-v1.mjs
import {
  compileTransactionMessage,
  decompileTransactionMessage,
  getCompiledTransactionMessageDecoder,
  getCompiledTransactionMessageEncoder,
} from '@solana/kit';

const input = process.argv[2] ?? (await new Promise(resolve => {
  let data = '';
  process.stdin.on('data', chunk => (data += chunk));
  process.stdin.on('end', () => resolve(data));
}));

const legacy = getCompiledTransactionMessageDecoder().decode(Buffer.from(input.trim(), 'base64'));
const message = decompileTransactionMessage(legacy);
const v1 = compileTransactionMessage({ ...message, version: 1 });
console.log(Buffer.from(getCompiledTransactionMessageEncoder().encode(v1)).toString('base64'));
