#!/usr/bin/env bash
# Deploys the relay: D1 migrations, the page Worker (waggle-relay), the files Worker
# (waggle-relay-files), and one shared TICKET_SECRET. Run from anywhere; needs `wrangler login`.
# Reads wrangler.deploy.jsonc (git-ignored): a copy of wrangler.jsonc with your own ids and hosts.
# The page Worker is a Cloudflare custom domain (its zone must be on Cloudflare). The files Worker
# stays on workers.dev; its name is the one in CONTENT_ORIGIN.
set -euo pipefail
cd "$(dirname "$0")/.."

config=wrangler.deploy.jsonc
if [ ! -f "$config" ]; then
  echo "No $config. Copy wrangler.jsonc to $config and set your own values (README.md, \"Run your own relay\")." >&2
  exit 1
fi
if grep -qE 'example\.com|YOUR-' "$config"; then
  echo "$config still has placeholders (example.com or YOUR-...). Set your own values first." >&2
  exit 1
fi
w() { npx wrangler "$@" --config "$config"; }

app_host=$(grep -oE '"pattern": *"[^"]+"' "$config" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
files_host=$(grep -oE 'waggle-relay-files\.[a-z0-9-]+\.workers\.dev' "$config" | head -1)

echo "== D1 migrations"
w d1 migrations apply waggle-relay --remote --env production

deploy() {
  local out
  out=$(w deploy --env "$1" 2>&1) || { echo "$out" >&2; exit 1; }
  printf '%s' "$out"
}

echo "== Page Worker (custom domain $app_host)"
deploy production >/dev/null

echo "== Files Worker"
deploy files >/dev/null

echo "== TICKET_SECRET (same value on both, never printed)"
if w secret list --env production 2>/dev/null | grep -q TICKET_SECRET; then
  echo "already set on waggle-relay; leaving it (rotate by deleting it on both first)"
else
  secret=$(openssl rand -hex 32)
  printf '%s' "$secret" | w secret put TICKET_SECRET --env production >/dev/null
  printf '%s' "$secret" | w secret put TICKET_SECRET --env files >/dev/null
  unset secret
  echo "set on both"
fi

echo "== Smoke test"
for host in "$app_host/d/none" "$files_host/"; do
  printf '%s -> ' "$host"; curl -s -o /dev/null -w '%{http_code}\n' "https://$host"
done
echo "Expected: 404 for both (no such case; the files host serves only ticket paths)."
