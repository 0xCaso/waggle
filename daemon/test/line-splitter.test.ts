import { describe, expect, test } from "bun:test";
import { LineSplitter } from "../src/line-splitter";
import { imageMimeType } from "../src/store";

const bytes = (s: string) => new TextEncoder().encode(s);

describe("LineSplitter", () => {
  test("splits lines across and within chunks", () => {
    const splitter = new LineSplitter();
    expect(splitter.push(bytes('{"a":1}\n{"b"'))).toEqual(['{"a":1}']);
    expect(splitter.push(bytes(":2}\n\n{\"c\":3}\n"))).toEqual(['{"b":2}', "", '{"c":3}']);
    expect(splitter.push(bytes("tail"))).toEqual([]);
  });

  test("keeps a multi-byte character split across chunks intact", () => {
    const splitter = new LineSplitter();
    const all = bytes("caffè ✓\n");
    expect(splitter.push(all.subarray(0, 4))).toEqual([]);
    expect(splitter.push(all.subarray(4, 6))).toEqual([]);
    expect(splitter.push(all.subarray(6))).toEqual(["caffè ✓"]);
  });

  test("a 20 MB line in 64 KB chunks splits in linear time", () => {
    const splitter = new LineSplitter();
    const chunk = new Uint8Array(64 * 1024).fill(0x41);
    const started = performance.now();
    for (let i = 0; i < 320; i++) expect(splitter.push(chunk)).toEqual([]);
    const lines = splitter.push(bytes("\n"));
    expect(lines[0]!.length).toBe(320 * 64 * 1024);
    expect(performance.now() - started).toBeLessThan(2000);
  });

  test("does not keep a reference to a chunk the runtime may reuse", () => {
    const splitter = new LineSplitter();
    const chunk = bytes("abc");
    splitter.push(chunk);
    chunk.fill(0x7a);
    expect(splitter.push(bytes("\n"))).toEqual(["abc"]);
  });
});

describe("imageMimeType", () => {
  test("tells JPEG from PNG by its base64 prefix", () => {
    expect(imageMimeType(Buffer.from([0xff, 0xd8, 0xff, 0xe0]).toString("base64"))).toBe("image/jpeg");
    expect(imageMimeType(Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64"))).toBe("image/png");
  });
});
