import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { RelaySharing, SHARING_AVAILABLE } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { SharingState } from "../src/protocol";
import { Store } from "../src/store";
import { rmrf, tmpHome } from "./helpers";

// Operator decision 8 Nov (case c_186e3e80): Sharing is hidden behind SHARING_AVAILABLE. Hidden means no relay
// call and nothing for the app to show, whatever the saved setting says.

let home: string;
let store: Store;
let calls: string[];
let sharing: RelaySharing;

beforeEach(() => {
  home = tmpHome();
  store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
  calls = [];
  const secrets = new MemorySecretStore();
  secrets.set("relay-device", "tok-device");
  // A Mac that had Sharing on before the hide.
  store.setConnectorSetting("relay", { enabled: true, account_email: "me@example.com" });
  sharing = new RelaySharing({
    store,
    secrets,
    available: false,
    baseUrl: "http://127.0.0.1:9",
    log: () => {},
    fetch: (async (url: string | URL | Request) => {
      calls.push(String(url));
      return new Response("{}", { status: 500 });
    }) as typeof fetch,
  });
});

afterEach(() => {
  sharing.stop();
  rmrf(home);
});

describe("Sharing hidden", () => {
  test("the switch is off in this version", () => {
    expect(SHARING_AVAILABLE).toBe(false);
  });

  test("the saved setting does not turn it on, and the state shows nothing", () => {
    expect(sharing.enabled()).toBe(false);
    const state = sharing.state("c_any");
    expect(SharingState.parse(state)).toEqual(state);
    expect(state.available).toBe(false);
    expect(state.enabled).toBe(false);
    expect(state.share).toBeNull();
    expect(state.account.signed_in).toBe(false);
  });

  test("it cannot be turned on", () => {
    expect(() => sharing.setEnabled(true)).toThrow("Sharing is not available in this version.");
  });

  test("the background makes no relay call", async () => {
    await (sharing as unknown as { tick(): Promise<void> }).tick();
    expect(calls).toEqual([]);
  });
});
