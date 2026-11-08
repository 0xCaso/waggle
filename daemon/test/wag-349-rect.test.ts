import { describe, expect, test } from "bun:test";
import { Rect } from "../src/protocol/nouns";

describe("WAG-349 Rect float error", () => {
  test("clamps a value within 1e-6 of the bounds", () => {
    expect(Rect.parse({ x: 0.0055, y: 0, w: 0.389, h: 1.0000000000000002 })).toEqual({ x: 0.0055, y: 0, w: 0.389, h: 1 });
    expect(Rect.parse({ x: -1e-9, y: 0, w: 1, h: 1 }).x).toBe(0);
  });
  test("still rejects clearly wrong values", () => {
    expect(Rect.safeParse({ x: 0, y: 0, w: 1.001, h: 1 }).success).toBe(false);
    expect(Rect.safeParse({ x: -0.01, y: 0, w: 1, h: 1 }).success).toBe(false);
    expect(Rect.safeParse({ x: "0", y: 0, w: 1, h: 1 }).success).toBe(false);
  });
});
