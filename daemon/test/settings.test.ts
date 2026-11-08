import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { getGuide, PRESET_INSTRUCTIONS } from "../src/guide";
import { DEFAULT_ASK_PREFERENCES, DETAIL_SENTENCES, learnSentence, REACH_SENTENCES, askAgentText, askPreferencesText } from "../src/guide/asks";
import { ASD_STE100_SECTION } from "../src/guide/ste100";
import {
  ArtifactPreset,
  SettingsGetParams,
  SettingsSetParams,
  rpcMethods,
} from "../src/protocol";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";
import pkg from "../package.json" with { type: "json" };

// HAIL-100: the Artifacts preset. The daemon persists it (settings.get /
// settings.set) and appends its instructions to the waggle_guide "artifacts"
// topic on every read.

const homes: string[] = [];
const servers: RpcServer[] = [];

afterEach(() => {
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

function setup(): { home: string; dbPath: string; store: Store; socketPath: string } {
  const home = tmpHome();
  homes.push(home);
  const dbPath = join(home, "knock.db");
  const store = new Store(new Database(dbPath), home, new EventBus());
  return { home, dbPath, store, socketPath: join(home, "knock.sock") };
}

function start(store: Store, socketPath: string): RpcServer {
  const server = startRpcServer({ socketPath, store, bus: new EventBus(), version: pkg.version });
  servers.push(server);
  return server;
}

describe("settings schemas", () => {
  test("accepts only the three presets and the one key", () => {
    expect(ArtifactPreset.options).toEqual(["quick", "visual", "rich"]);
    expect(SettingsSetParams.safeParse({ key: "artifactPreset", value: "rich" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "artifactPreset", value: "custom" }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "other", value: "rich" }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "artifactPreset", value: "rich", x: 1 }).success).toBe(false);
    expect(SettingsGetParams.safeParse({ key: "artifactPreset" }).success).toBe(true);
    expect(Object.keys(rpcMethods)).toContain("settings.get");
    expect(Object.keys(rpcMethods)).toContain("settings.set");
  });
});

describe("artifact preset persistence", () => {
  test("defaults to visual when unset", () => {
    const { store } = setup();
    expect(store.getArtifactPreset()).toBe("visual");
  });

  test("survives a reopen of the database", () => {
    const { home, dbPath, store } = setup();
    store.setArtifactPreset("quick");
    const again = new Store(new Database(dbPath), home, new EventBus());
    expect(again.getArtifactPreset()).toBe("quick");
    again.setArtifactPreset("rich");
    expect(again.getArtifactPreset()).toBe("rich");
  });

  test("a stored value that is no longer valid reads as the default", () => {
    const { store } = setup();
    store.setArtifactPreset("rich");
    (store as unknown as { db: Database }).db.exec(
      "UPDATE settings SET value = 'gone' WHERE key = 'artifactPreset'",
    );
    expect(store.getArtifactPreset()).toBe("visual");
  });
});

describe("settings RPC", () => {
  test("get returns the default, set persists, bad values are rejected", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);

    const first = await client.request("settings.get", { key: "artifactPreset" });
    expect(first.result).toEqual({ key: "artifactPreset", value: "visual" });

    const set = await client.request("settings.set", { key: "artifactPreset", value: "quick" });
    expect(set.result).toEqual({ key: "artifactPreset", value: "quick" });
    const after = await client.request("settings.get", { key: "artifactPreset" });
    expect(after.result).toEqual({ key: "artifactPreset", value: "quick" });

    const bad = await client.request("settings.set", { key: "artifactPreset", value: "custom" });
    expect(bad.error).toBeDefined();
    expect(store.getArtifactPreset()).toBe("quick");
    client.close();
  });

  test("guide.get artifacts follows the preset on the next read", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    const read = async () =>
      ((await client.request("guide.get", { topic: "artifacts" })).result as { text: string }).text;

    expect(await read()).toContain(PRESET_INSTRUCTIONS.visual);
    await client.request("settings.set", { key: "artifactPreset", value: "rich" });
    const rich = await read();
    expect(rich).toContain(PRESET_INSTRUCTIONS.rich);
    expect(rich).not.toContain(PRESET_INSTRUCTIONS.visual);
    client.close();
  });
});

describe("guide operator preferences", () => {
  for (const preset of ArtifactPreset.options) {
    test(`artifacts topic ends with the ${preset} section`, () => {
      const text = getGuide("artifacts", preset);
      expect(text.trimEnd().endsWith(`## Operator preferences\n\n${PRESET_INSTRUCTIONS[preset]}`)).toBe(true);
      expect(text.match(/## Operator preferences/g)?.length).toBe(1);
    });
  }

  test("defaults to visual, and other topics carry no section", () => {
    expect(getGuide("artifacts")).toContain(PRESET_INSTRUCTIONS.visual);
    for (const topic of ["writing-an-ask", "reviews", "after-the-reply", "whats-new"]) {
      expect(getGuide(topic, "rich")).not.toContain("Operator preferences");
    }
  });

  test("exact agent text", () => {
    expect(PRESET_INSTRUCTIONS.quick).toBe(
      "Keep artifacts light: markdown or one short plain HTML page, tables over charts. A preview card is optional. No bundled React.",
    );
  });
});

// HAIL-101: ask preferences (topics, frequency, detail) and the generated text.
describe("ask preferences", () => {
  test("schemas accept only the known values and keys", () => {
    expect(SettingsSetParams.safeParse({ key: "askFrequency", value: "chat" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askFrequency", value: "rich" }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "askDetail", value: "rich" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askDetail", value: "medium" }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "askTopics", value: { scope: "pick", picked: ["code"] } }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askTopics", value: { scope: "pick", picked: ["cooking"] } }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "askTopics", value: "code" }).success).toBe(false);
    expect(SettingsSetParams.safeParse({ key: "askWords", value: "normal" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askWords", value: "plain" }).success).toBe(false);
    expect(SettingsGetParams.safeParse({ key: "askWords" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askText", value: "x" }).success).toBe(false);
    expect(SettingsGetParams.safeParse({ key: "askText" }).success).toBe(true);
  });

  test("defaults, persistence and reopen", () => {
    const { home, dbPath, store } = setup();
    expect(store.getAskTopics().scope).toBe("any");
    expect(store.getAskFrequency()).toBe("choice");
    expect(store.getAskDetail()).toBe("brief");
    expect(store.getAskWords()).toBe("asd");
    store.setAskTopics({ scope: "pick", picked: ["pricing", "pricing", "data"] });
    store.setAskFrequency("blocked");
    store.setAskDetail("rich");
    store.setAskWords("normal");
    const again = new Store(new Database(dbPath), home, new EventBus());
    expect(again.getAskTopics()).toEqual({ scope: "pick", picked: ["pricing", "data"] });
    expect(again.getAskFrequency()).toBe("blocked");
    expect(again.getAskDetail()).toBe("rich");
    expect(again.getAskWords()).toBe("normal");
  });

  test("a stored value that is no longer valid reads as the default", () => {
    const { store } = setup();
    store.setAskDetail("rich");
    (store as unknown as { db: Database }).db.exec("UPDATE settings SET value = 'nope' WHERE key = 'askDetail'");
    expect(store.getAskDetail()).toBe("brief");
  });

  test("the generated text", () => {
    const base = DEFAULT_ASK_PREFERENCES;
    expect(askPreferencesText(base)).toBe(
      "Ask me in Waggle (waggle_ask), not in the terminal, whenever there is a real choice to make, whatever the topic. " +
        "Keep working on anything that does not depend on my answer. " +
        DETAIL_SENTENCES.brief,
    );
    const picked = askPreferencesText({
      topics: { scope: "pick", picked: ["design", "code", "reviews"] },
      frequency: "chat",
      detail: "rich",
      reach: "everything",
    });
    expect(picked).toContain(
      "for anything you would normally ask me in the chat: design and UX; code and architecture; reviews before something ships.",
    );
    expect(picked.endsWith(DETAIL_SENTENCES.rich)).toBe(true);
    // Picking nothing reads like "anything".
    expect(askPreferencesText({ ...base, topics: { scope: "pick", picked: [] } })).toContain("whatever the topic");
    // The picked list is kept but unused while the scope is "any".
    expect(askPreferencesText({ ...base, topics: { scope: "any", picked: ["code"] } })).not.toContain("code and");
  });

  test("askReach: validation, default, persistence", () => {
    expect(SettingsSetParams.safeParse({ key: "askReach", value: "written" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askReach", value: "all" }).success).toBe(false);
    expect(SettingsGetParams.safeParse({ key: "askReach" }).success).toBe(true);
    const { home, dbPath, store } = setup();
    expect(store.getAskReach()).toBe("everything");
    store.setAskReach("visual");
    expect(new Store(new Database(dbPath), home, new EventBus()).getAskReach()).toBe("visual");
    (store as unknown as { db: Database }).db.exec("UPDATE settings SET value = 'nope' WHERE key = 'askReach'");
    expect(store.getAskReach()).toBe("everything");
  });

  test("askReach: text per level, no contradiction below everything", () => {
    const base = DEFAULT_ASK_PREFERENCES;
    const everything = askPreferencesText({ ...base, reach: "everything" });
    // Byte-identical to the text before askReach existed.
    expect(everything).toBe(
      "Ask me in Waggle (waggle_ask), not in the terminal, whenever there is a real choice to make, whatever the topic. " +
        "Keep working on anything that does not depend on my answer. " +
        DETAIL_SENTENCES.brief,
    );
    for (const reach of ["written", "visual"] as const) {
      const text = askPreferencesText({ ...base, reach });
      expect(text).toContain(REACH_SENTENCES[reach]);
      expect(text).not.toContain("not in the terminal,");
      expect(text.startsWith("Ask me in Waggle (waggle_ask) whenever there is a real choice to make, whatever the topic. ")).toBe(true);
      expect(text.endsWith(DETAIL_SENTENCES.brief)).toBe(true);
    }
    expect(REACH_SENTENCES.written).toBe(
      "Bring me asks with something to look at or to read (a write-up, a draft, a plan) in Waggle. Ask a quick question I can answer in a word or a yes/no (a name, a default, a go-ahead) in the terminal.",
    );
    expect(REACH_SENTENCES.visual).toBe(
      "Use Waggle only for asks with something to look at: a prototype, designs, screenshots, a chart or a page. Ask everything else in the terminal, including write-ups and quick questions.",
    );
  });

  test("RPC: askReach set, get and askText", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    expect((await client.request("settings.get", { key: "askReach" })).result).toEqual({ key: "askReach", value: "everything" });
    expect((await client.request("settings.set", { key: "askReach", value: "written" })).result).toEqual({ key: "askReach", value: "written" });
    const text = ((await client.request("settings.get", { key: "askText" })).result as { value: string }).value;
    expect(text).toContain(REACH_SENTENCES.written);
    expect((await client.request("settings.set", { key: "askReach", value: "none" })).error).toBeDefined();
    client.close();
  });

  test("RPC: set, get and askText follow each other; askText cannot be set", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    const text = async () =>
      ((await client.request("settings.get", { key: "askText" })).result as { value: string }).value;

    expect(await text()).toBe(askAgentText(DEFAULT_ASK_PREFERENCES));
    const topics = { scope: "pick", picked: ["design", "writing"] };
    expect((await client.request("settings.set", { key: "askTopics", value: topics })).result).toEqual({
      key: "askTopics",
      value: topics,
    });
    await client.request("settings.set", { key: "askFrequency", value: "blocked" });
    await client.request("settings.set", { key: "askDetail", value: "rich" });
    expect((await client.request("settings.get", { key: "askDetail" })).result).toEqual({ key: "askDetail", value: "rich" });
    const after = await text();
    expect(after).toContain("only when you are blocked on me: design and UX; writing and naming.");
    expect(after).toContain(DETAIL_SENTENCES.rich);
    expect((await client.request("settings.set", { key: "askText", value: "x" })).error).toBeDefined();
    expect((await client.request("settings.set", { key: "askTopics", value: { scope: "pick", picked: ["x"] } })).error).toBeDefined();
    // The artifact preset still works beside them (HAIL-100).
    await client.request("settings.set", { key: "artifactPreset", value: "rich" });
    expect(store.getArtifactPreset()).toBe("rich");
    client.close();
  });

  test("waggle_guide index ends with the preferences section; topics do not carry it", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    await client.request("settings.set", { key: "askDetail", value: "rich" });
    const index = ((await client.request("guide.get", {})).result as { text: string }).text;
    expect(index).toContain("Waggle guide topics.");
    expect(index.trimEnd().endsWith(`## Operator preferences · asks\n\n${askAgentText(store.getAskPreferences())}`)).toBe(true);
    const artifacts = ((await client.request("guide.get", { topic: "artifacts" })).result as { text: string }).text;
    expect(artifacts).not.toContain("Operator preferences · asks");
    expect(artifacts).toContain("## Operator preferences\n");
    client.close();
  });

  test("askWords: validation, default, persistence, invalid reads as default", () => {
    expect(SettingsGetParams.safeParse({ key: "askWords" }).success).toBe(true);
    const { home, dbPath, store } = setup();
    expect(store.getAskWords()).toBe("asd");
    store.setAskWords("normal");
    expect(new Store(new Database(dbPath), home, new EventBus()).getAskWords()).toBe("normal");
    (store as unknown as { db: Database }).db.exec("UPDATE settings SET value = 'nope' WHERE key = 'askWords'");
    expect(store.getAskWords()).toBe("asd");
  });

  test("askLearn: default short, each value persists, unknown value refused", () => {
    expect(SettingsGetParams.safeParse({ key: "askLearn" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askLearn", value: "poem" }).success).toBe(false);
    const { home, dbPath, store } = setup();
    expect(store.getAskLearn()).toBe("short");
    for (const v of ["diagram", "steps", "try", "short"] as const) {
      store.setAskLearn(v);
      expect(new Store(new Database(dbPath), home, new EventBus()).getAskLearn()).toBe(v);
      expect(SettingsSetParams.safeParse({ key: "askLearn", value: v }).success).toBe(true);
    }
    (store as unknown as { db: Database }).db.exec("UPDATE settings SET value = 'nope' WHERE key = 'askLearn'");
    expect(store.getAskLearn()).toBe("short");
  });

  test("askText carries one learn line for the chosen style", () => {
    const lines = {
      short: "Answer in up to 3 short lines. Cite the files you read.",
      diagram: "Start with a diagram of the parts, then up to 3 short lines. Cite the files you read.",
      steps: "Use numbered steps. Cite the files you read.",
      try: "Send a small html_bundle they can click through. Cite the files you read.",
    } as const;
    for (const learn of ["short", "diagram", "steps", "try"] as const) {
      const text = askAgentText({ ...DEFAULT_ASK_PREFERENCES, learn });
      expect(text).toContain(`When the human asks how something works, explain only the part they name. ${lines[learn]}`);
    }
    expect(askAgentText({ ...DEFAULT_ASK_PREFERENCES, reach: "off" })).not.toContain("how something works");
  });

  test("RPC: askLearn set and get, askText follows", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    expect((await client.request("settings.get", { key: "askLearn" })).result).toEqual({ key: "askLearn", value: "short" });
    expect((await client.request("settings.set", { key: "askLearn", value: "steps" })).result).toEqual({ key: "askLearn", value: "steps" });
    const text = ((await client.request("settings.get", { key: "askText" })).result as { value: string }).value;
    expect(text).toContain("Use numbered steps.");
    expect((await client.request("settings.set", { key: "askLearn", value: "poem" })).error).toBeDefined();
    client.close();
  });

  test("the after-the-reply guide tells the agent how to answer a how-it-works request", () => {
    const g = getGuide("after-the-reply");
    expect(g).toContain("### How it works");
    expect(g).toContain("Explain how this works:");
    for (const w of ["`.mmd` or `.svg`", "html_bundle", "numbered steps", "up to 3 short lines", "sources", "same case"]) expect(g).toContain(w);
  });

  test("askText carries the ASD-STE100 section by default and drops it in normal", () => {
    const base = DEFAULT_ASK_PREFERENCES;
    const asd = askAgentText(base);
    expect(asd).toContain(ASD_STE100_SECTION);
    expect(asd.startsWith(askPreferencesText(base))).toBe(true);
    const normal = askAgentText({ ...base, words: "normal" });
    expect(normal).toBe(`${askPreferencesText(base)} ${learnSentence(base.learn)}`);
    expect(normal).not.toContain("ASD-STE100");
  });

  test("RPC: askWords set, get and askText follow each other", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    expect((await client.request("settings.get", { key: "askWords" })).result).toEqual({ key: "askWords", value: "asd" });
    const text = async () =>
      ((await client.request("settings.get", { key: "askText" })).result as { value: string }).value;
    expect(await text()).toContain(ASD_STE100_SECTION);
    expect((await client.request("settings.set", { key: "askWords", value: "normal" })).result).toEqual({ key: "askWords", value: "normal" });
    expect(await text()).not.toContain("ASD-STE100");
    expect((await client.request("settings.set", { key: "askWords", value: "plain" })).error).toBeDefined();
    client.close();
  });

  test("writing-an-ask guide carries the section by default and not in normal", async () => {
    const { store, socketPath } = setup();
    start(store, socketPath);
    const client = await rpcConnect(socketPath);
    const read = async () =>
      ((await client.request("guide.get", { topic: "writing-an-ask" })).result as { text: string }).text;
    expect(await read()).toContain(ASD_STE100_SECTION);
    await client.request("settings.set", { key: "askWords", value: "normal" });
    expect(await read()).not.toContain("ASD-STE100");
    client.close();
  });
});
