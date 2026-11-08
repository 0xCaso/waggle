// Splits a byte stream into newline-terminated lines (the socket's JSON-RPC
// framing, docs/protocol-mvp.md). Linear in the bytes received: each chunk is
// searched for "\n" once, and a partial line is kept as a list of chunks until
// its newline arrives. The old `buffer += chunk; buffer.indexOf("\n")` loop
// rescanned the whole partial line on every chunk, which is quadratic: a
// 17.8 MB reply.submit with captures took long enough that the app's refreshes
// timed out. Decoding bytes per complete line, not per chunk, also keeps a
// multi-byte UTF-8 character that straddles two chunks intact.
export class LineSplitter {
  private pending: Uint8Array[] = [];

  push(chunk: Uint8Array): string[] {
    const lines: string[] = [];
    let start = 0;
    let newline: number;
    while ((newline = chunk.indexOf(0x0a, start)) >= 0) {
      this.pending.push(chunk.subarray(start, newline));
      lines.push(decoder.decode(concat(this.pending)));
      this.pending = [];
      start = newline + 1;
    }
    // Copy the tail: the runtime may reuse the chunk's memory after this call.
    if (start < chunk.length) this.pending.push(chunk.slice(start));
    return lines;
  }
}

const decoder = new TextDecoder();

function concat(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 1) return parts[0]!;
  let length = 0;
  for (const part of parts) length += part.length;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
