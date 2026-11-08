// Where connector secrets live (HAIL-144, PLAN section 9): the macOS Keychain. A secret never
// goes to knock.db, a log, or an RPC result.

export interface SecretStore {
  get(account: string): string | null;
  set(account: string, value: string): void;
  delete(account: string): void;
}

const SERVICE = "Knock chat connector";

function security(args: string[]): { code: number; out: string } {
  const proc = Bun.spawnSync(["/usr/bin/security", ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: proc.exitCode ?? 1, out: proc.stdout.toString() };
}

// The login Keychain, through /usr/bin/security. `account` carries the bundle id so a dev build
// never reads the real app's item.
export class KeychainSecretStore implements SecretStore {
  private account(name: string): string {
    return `${process.env.KNOCK_BUNDLE_ID?.trim() || "dev.limone.knock"}.${name}`;
  }

  get(name: string): string | null {
    const r = security(["find-generic-password", "-s", SERVICE, "-a", this.account(name), "-w"]);
    if (r.code !== 0) return null;
    const value = r.out.replace(/\n$/, "");
    return value === "" ? null : value;
  }

  set(name: string, value: string): void {
    const r = security(["add-generic-password", "-U", "-s", SERVICE, "-a", this.account(name), "-w", value]);
    if (r.code !== 0) throw new Error("could not save to the Keychain");
  }

  delete(name: string): void {
    security(["delete-generic-password", "-s", SERVICE, "-a", this.account(name)]);
  }
}

// Holds secrets in memory only. Tests use it, and KNOCK_SECRET_STORE=memory selects it for
// evidence runs, so no run touches the real Keychain. Nothing reaches disk.
export class MemorySecretStore implements SecretStore {
  private values = new Map<string, string>();
  get(name: string): string | null {
    return this.values.get(name) ?? null;
  }
  set(name: string, value: string): void {
    this.values.set(name, value);
  }
  delete(name: string): void {
    this.values.delete(name);
  }
}

export function defaultSecretStore(env: NodeJS.ProcessEnv = process.env): SecretStore {
  return env.KNOCK_SECRET_STORE === "memory" ? new MemorySecretStore() : new KeychainSecretStore();
}
