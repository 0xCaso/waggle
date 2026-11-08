#!/usr/bin/env bun
// Generates a throwaway Ed25519 keypair for Sparkle tests and dry-runs
// (KNOCK-21). Never used for a real release: the maintainer's real key comes
// from generate_keys into the Keychain (docs/RELEASE.md), never a committed
// file.
//
// Sparkle's sign_update --ed-key-file reads the 32-byte Ed25519 seed as base64;
// the matching public key (base64) is the app's SUPublicEDKey. Node's Ed25519
// is byte-compatible with Sparkle's vendored ed25519, so a key written here
// signs exactly like generate_keys (verified in the story).
//
//   sparkle-ed25519.mjs generate <dir>
//     writes <dir>/ed25519.seed and <dir>/ed25519.pub, prints the public key.
import { generateKeyPairSync } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const cmd = process.argv[2];

if (cmd === "generate") {
  const dir = process.argv[3];
  if (!dir) {
    process.stderr.write("usage: sparkle-ed25519.mjs generate <dir>\n");
    process.exit(2);
  }
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const pubJwk = publicKey.export({ format: "jwk" });
  const privJwk = privateKey.export({ format: "jwk" });
  // d is the 32-byte seed (base64url), x is the 32-byte public key (base64url).
  const seed = Buffer.from(privJwk.d, "base64url");
  const pub = Buffer.from(pubJwk.x, "base64url");
  writeFileSync(join(dir, "ed25519.seed"), seed.toString("base64") + "\n");
  writeFileSync(join(dir, "ed25519.pub"), pub.toString("base64") + "\n");
  process.stdout.write(pub.toString("base64") + "\n");
} else {
  process.stderr.write("usage: sparkle-ed25519.mjs generate <dir>\n");
  process.exit(2);
}
