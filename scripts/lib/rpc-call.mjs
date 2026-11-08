#!/usr/bin/env bun
// Sends one JSON-RPC request over a Waggle unix socket and prints the result as
// JSON. scripts/update-e2e.sh uses it to assert the running daemon's version
// (service.status) without a dedicated CLI subcommand.
//
//   rpc-call.mjs <socket> <method> [params-json]
import { createConnection } from "node:net";

const [sock, method, paramsJson] = process.argv.slice(2);
if (!sock || !method) {
  process.stderr.write("usage: rpc-call.mjs <socket> <method> [params-json]\n");
  process.exit(2);
}

let params = {};
if (paramsJson) {
  try {
    params = JSON.parse(paramsJson);
  } catch {
    process.stderr.write("rpc-call: params is not valid JSON\n");
    process.exit(2);
  }
}

const request = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) + "\n";
const conn = createConnection(sock);
let buffer = "";

const timer = setTimeout(() => {
  process.stderr.write("rpc-call: timeout waiting for a response\n");
  process.exit(1);
}, 10_000);

conn.on("connect", () => conn.write(request));
conn.on("data", (data) => {
  buffer += data.toString("utf8");
  const newline = buffer.indexOf("\n");
  if (newline < 0) return;
  clearTimeout(timer);
  const line = buffer.slice(0, newline);
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    process.stderr.write(`rpc-call: bad response: ${line}\n`);
    process.exit(1);
  }
  if (message.error) {
    process.stderr.write(`rpc-call: ${JSON.stringify(message.error)}\n`);
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(message.result) + "\n");
  process.exit(0);
});
conn.on("error", (err) => {
  clearTimeout(timer);
  process.stderr.write(`rpc-call: ${err.message}\n`);
  process.exit(1);
});
