export * from "./naming";

// A process is alive when signal 0 reaches it. ESRCH means "no such process";
// EPERM means it exists but this user may not signal it, so it is still alive.
export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code !== "ESRCH";
  }
}
