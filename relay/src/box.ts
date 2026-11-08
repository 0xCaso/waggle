// Runs in the sandboxed frame too: the frame script embeds this function with toString().
// Keep it self-contained and plain, with no reference to anything outside its body.
//
// An area is stored in document pixels at the frame width of that time (box.vw). When the frame
// is another width the text reflows. x and w scale by (current width / stored width) so the
// outline stays on its text; y and h stay, as the height of reflowed text is not known.
export function scaleBox(
  b: { x: number; y: number; w: number; h: number; vw?: number },
  width: number,
): { x: number; y: number; w: number; h: number } {
  var k = b.vw && b.vw > 0 && width > 0 ? width / b.vw : 1;
  return { x: b.x * k, y: b.y, w: b.w * k, h: b.h };
}
