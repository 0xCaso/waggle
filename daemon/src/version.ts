// Dotted-version comparison, mirroring the app's version order (KNOCK-21).
// Each component compares as an integer; a shorter version equals the longer
// one on its missing trailing components.

// True when `candidate` is older than `than`.
export function isOlder(candidate: string, than: string): boolean {
  const a = candidate.split(".");
  const b = than.split(".");
  const count = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) {
    const av = component(a[i]);
    const bv = component(b[i]);
    if (av < bv) return true;
    if (av > bv) return false;
  }
  return false;
}

function component(part: string | undefined): number {
  const parsed = Number(part ?? "");
  return Number.isFinite(parsed) ? parsed : 0;
}
