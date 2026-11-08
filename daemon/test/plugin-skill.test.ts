import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { getGuide } from "../src/guide";
import { dirname, join } from "node:path";

// HAIL-239: the Waggle Claude Code plugin ships the waggle-prototype skill with the
// make-interfaces-feel-better references and its MIT license. scripts/bundle-app.sh copies
// the whole plugin folder (only tests and tsconfig stay out), so a file here is a file in the app.

const PLUGIN = join(import.meta.dir, "..", "..", "plugins", "claude-code", "waggle");
const SKILL = join(PLUGIN, "skills", "waggle-prototype");
const read = (p: string) => readFileSync(p, "utf8");

describe("waggle-prototype skill", () => {
  test("has a SKILL.md that triggers on prototypes, html_bundles and variants", () => {
    const skill = read(join(SKILL, "SKILL.md"));
    expect(skill).toMatch(/^---\nname: waggle-prototype\n/);
    const description = skill.match(/^description: (.+)$/m)?.[1] ?? "";
    for (const word of ["prototype", "html_bundle", "variant", "waggle_ask"]) expect(description).toContain(word);
  });

  test("carries the make-interfaces-feel-better references, license and credit", () => {
    for (const f of ["animations.md", "icons.md", "performance.md", "surfaces.md", "typography.md"]) {
      expect(existsSync(join(SKILL, f))).toBe(true);
    }
    expect(read(join(SKILL, "LICENSE-make-interfaces-feel-better"))).toContain("MIT License");
    const skill = read(join(SKILL, "SKILL.md"));
    expect(skill).toContain("Jakub Krehel");
    expect(skill).toContain("https://github.com/jakubkrehel/make-interfaces-feel-better");
    expect(skill).toContain("## Core Principles");
  });

  test("maps the Waggle moments to the impeccable commands, with a fallback", () => {
    const skill = read(join(SKILL, "SKILL.md"));
    expect(skill).toContain("## 4. Waggle moments");
    for (const cmd of ["`shape`", "`polish`", "`critique`", "`audit`", "`harden`"]) expect(skill).toContain(cmd);
    expect(skill).toContain("If it is not available");
  });

  test("keeps Waggle-only tokens and no em-dashes out of the skill text", () => {
    const own = read(join(SKILL, "SKILL.md")).split("## 5. Polish details")[0];
    expect(own).not.toMatch(/#F9C846|honey|Cell W|Inter Tight/i);
    expect(own).not.toContain("—");
  });

  test("the plugin version is bumped past 0.3.0 in both manifests", () => {
    const plugin = JSON.parse(read(join(PLUGIN, ".claude-plugin", "plugin.json")));
    const root = JSON.parse(read(join(PLUGIN, "..", "..", "..", ".claude-plugin", "marketplace.json")));
    expect(plugin.version).toBe("0.4.0");
    expect(root.plugins[0].version).toBe(plugin.version);
  });

  test("bundle-app.sh does not exclude the skill's files", () => {
    const script = read(join(import.meta.dir, "..", "..", "scripts", "bundle-app.sh"));
    expect(script).toContain("--exclude='*.test.*' --exclude='tsconfig.json'");
    expect(script).not.toMatch(/--exclude='(\*\.md|LICENSE\*|skills)'/);
  });
});

// WAG-261: design-system.md gives exact search steps. This test runs the documented globs on four
// fixture projects and checks that each fixture's token source is found and holds tokens.

const FIXTURES = join(import.meta.dir, "fixtures", "design-systems");
const REF = read(join(SKILL, "design-system.md"));
const STEPS = REF.split("## 2. Search steps")[1].split("## 3.")[0];
const GLOBS = [...STEPS.matchAll(/^\| \d \|[^|]*\|([^|]*)\|/gm)].flatMap((m) => [...m[1].matchAll(/`([^`]+)`/g)].map((g) => g[1])).filter((g) => /[./]/.test(g) && !g.includes(" "));

function found(project: string): string[] {
  const root = join(FIXTURES, project);
  const hits = new Set<string>();
  for (const g of GLOBS) for (const f of new Bun.Glob(g).scanSync({ cwd: root, dot: true })) hits.add(f);
  return [...hits];
}

describe("design-system.md discovery steps", () => {
  test("is linked from SKILL.md and covers every source in the spec", () => {
    expect(read(join(SKILL, "SKILL.md"))).toContain("design-system.md");
    for (const w of ["DESIGN.md", "@theme", "tailwind.config", ".xcassets", "ui/theme", "tokens.css", ".waggle/design-tokens.json", "sha256", "No design system found; neutral style.", "Uses your design system:"]) {
      expect(REF).toContain(w);
    }
    expect(REF).not.toContain("—");
  });

  const cases: [string, string, RegExp][] = [
    ["css-vars", "src/styles/globals.css", /--color-brand:/],
    ["tailwind-v3", "tailwind.config.js", /colors:\s*\{\s*brand/],
    ["tailwind-v4", "src/app.css", /@theme/],
    ["swift-theme", "App/Theme/Theme.swift", /static let brand/],
    ["inline-html", "install/index.html", /<style>\s*:root\{--ink:/],
  ];
  for (const [project, source, marker] of cases) {
    test(`finds the token source of the ${project} fixture`, () => {
      const hits = found(project);
      expect(hits).toContain(source);
      expect(read(join(FIXTURES, project, source))).toMatch(marker);
    });
  }

  test("finds inline :root tokens in every page and the Google Fonts link (no .css file)", () => {
    const hits = found("inline-html");
    expect(hits).toContain("index.html");
    expect(hits.some((f) => f.endsWith(".css"))).toBe(false);
    for (const f of hits) expect(read(join(FIXTURES, "inline-html", f))).toMatch(/:root\{--ink:/);
    expect(read(join(FIXTURES, "inline-html", "index.html"))).toContain("fonts.googleapis.com");
  });

  test("finds the waggle.so site tokens by the documented steps", () => {
    const site = join(import.meta.dir, "..", "..", "site");
    const hits = new Set<string>();
    for (const g of GLOBS) for (const f of new Bun.Glob(g).scanSync({ cwd: site, dot: true })) hits.add(f);
    expect(hits).toContain("index.html");
    expect(hits).toContain("install/index.html");
    expect(read(join(site, "install", "index.html"))).toMatch(/:root\{--ink:/);
  });

  test("documents the disagreement rule, the main source, N colours and the render widths", () => {
    for (const w of ["most files use", "main source", "distinct colour tokens", "inline SVG colours", "git top-level", "`<style>`"]) expect(REF.toLowerCase()).toContain(w.toLowerCase());
    expect(read(join(SKILL, "SKILL.md"))).toMatch(/1400, 900 and 390/);
  });

  test("monorepo: discovery from the site folder picks the site, not the app or the repo docs", () => {
    const repo = join(FIXTURES, "monorepo");
    // Documented rule: go up from the target file to the nearest folder with its own project marker.
    const MARKERS = ["package.json", "Package.swift", "pyproject.toml", "build.gradle", "pubspec.yaml"];
    expect(REF).toContain("nearest");
    for (const m of MARKERS) expect(REF).toContain(m);
    const projectFolder = (target: string) => {
      let dir = join(repo, dirname(target));
      while (dir.startsWith(repo) && dir !== repo) {
        if (MARKERS.some((m) => existsSync(join(dir, m)))) return dir;
        dir = dirname(dir);
      }
      return repo;
    };
    const run = (cwd: string) => {
      const hits = new Set<string>();
      for (const g of GLOBS) for (const f of new Bun.Glob(g).scanSync({ cwd, dot: true })) hits.add(f);
      return [...hits];
    };
    const site = projectFolder("site/install/index.html");
    expect(site).toBe(join(repo, "site"));
    const siteHits = run(site);
    expect(siteHits).toContain("index.html");
    expect(siteHits.some((f) => f.endsWith(".swift") || f.endsWith(".md"))).toBe(false);
    const app = projectFolder("app/Sources/Theme/Theme.swift");
    expect(app).toBe(join(repo, "app"));
    expect(run(app)).toContain("Sources/Theme/Theme.swift");
    // Searching from the repo root would also pick the app and the repo docs: that is why the scope rule exists.
    const rootHits = run(repo);
    expect(rootHits).toContain("docs/design/mvp-values.md");
    expect(rootHits).toContain("app/Sources/Theme/Theme.swift");
  });

  test("documents scope, skip folders, single spacing token and the source line folder", () => {
    for (const w of [".claude/worktrees", ".knock-review", "`.waggle`", "widen", "searched in", "One spacing value is not a scale", "inside CSS rules"]) expect(REF).toContain(w);
  });

  test("finds the Swift asset catalog colour", () => {
    expect(found("swift-theme")).toContain("App/Assets.xcassets/Brand.colorset/Contents.json");
  });
});

// WAG-266: the waggle-diagram skill is an adapted copy of diagram-design (MIT). It keeps the layout
// rules and the two check scripts and takes colours and fonts from the project's design system.

const DIAGRAM = join(PLUGIN, "skills", "waggle-diagram");
const FIXTURES_DIAGRAMS = join(import.meta.dir, "fixtures", "diagrams");

function py(script: string, file: string) {
  const r = Bun.spawnSync(["python3", "-I", join(DIAGRAM, "scripts", script), file], { stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode, out: r.stdout.toString() + r.stderr.toString() };
}

describe("waggle-diagram skill", () => {
  const skill = read(join(DIAGRAM, "SKILL.md"));

  test("is listed with a trigger description, the licence and the attribution", () => {
    expect(skill).toMatch(/^---\nname: waggle-diagram\n/);
    const description = skill.match(/^description: (.+)$/m)?.[1] ?? "";
    for (const word of ["diagram", "waggle_ask", "design system"]) expect(description).toContain(word);
    expect(read(join(DIAGRAM, "LICENSE-diagram-design"))).toContain("MIT License");
    expect(read(join(DIAGRAM, "LICENSE-diagram-design"))).toContain("Cathryn Lavery");
    expect(skill).toContain("https://github.com/cathrynlavery/diagram-design");
  });

  test("every reference and script named in the skill files exists", () => {
    const files = ["SKILL.md", ...["types", "semantic-patterns", "geometry", "output"].map((n) => `references/${n}.md`)];
    for (const f of files) {
      const text = read(join(DIAGRAM, f));
      for (const m of text.matchAll(/`((?:references|scripts)\/[\w.-]+)`/g)) expect(existsSync(join(DIAGRAM, m[1]))).toBe(true);
      for (const m of text.matchAll(/`(\.\.\/[\w./-]+)`/g)) expect(existsSync(join(DIAGRAM, m[1]))).toBe(true);
    }
    for (const f of ["scripts/verify-geometry.py", "scripts/self_check.py"]) expect(existsSync(join(DIAGRAM, f))).toBe(true);
  });

  test("keeps the rules and drops the upstream brand", () => {
    const all = ["SKILL.md", "references/geometry.md", "references/output.md", "references/types.md", "references/semantic-patterns.md"].map((f) => read(join(DIAGRAM, f))).join("\n");
    for (const w of ["9 nodes", "12 arrows", "Orthogonal only", "6 to 10 px", "4 px", "Confirm the plan", "1 or 2 focal", "No design system found; neutral style."]) expect(all).toContain(w);
    expect(skill).not.toContain("—");
    expect(all).not.toContain("—");
    expect(all).not.toMatch(/#eb6c36|#f5f5f5.*coral|font-family="'Geist/i);
    expect(skill).toContain("../waggle-prototype/design-system.md");
    expect(existsSync(join(SKILL, "design-system.md"))).toBe(true);
    expect(read(join(DIAGRAM, "references", "types.md")).match(/^\| .+ \| .+ \|$/gm)!.length).toBeGreaterThanOrEqual(44);
  });

  test("waggle-prototype points flows and diagrams to it, and the guide and whats-new say it", () => {
    expect(read(join(SKILL, "SKILL.md"))).toContain("use the waggle-diagram skill");
    expect(getGuide("artifacts")).toContain("waggle-diagram skill");
    expect(getGuide("whats-new")).toContain("waggle-diagram skill");
  });

  test("the geometry check passes a good SVG and fails a diagonal connector and 10 nodes", () => {
    expect(py("verify-geometry.py", join(FIXTURES_DIAGRAMS, "good.svg")).code).toBe(0);
    const diagonal = py("verify-geometry.py", join(FIXTURES_DIAGRAMS, "bad-diagonal.svg"));
    expect(diagonal.code).toBe(1);
    expect(diagonal.out).toContain("diagonal");
    const ten = py("verify-geometry.py", join(FIXTURES_DIAGRAMS, "bad-ten-nodes.svg"));
    expect(ten.code).toBe(1);
    expect(ten.out).toContain("10 nodes");
  });

  test("the self check passes a good SVG and fails a script, a remote file and a missing title", () => {
    expect(py("self_check.py", join(FIXTURES_DIAGRAMS, "good.svg")).code).toBe(0);
    const dir = mkdtempSync(join(tmpdir(), "waggle-diagram-"));
    const bad = join(dir, "bad.svg");
    writeFileSync(bad, '<svg xmlns="http://www.w3.org/2000/svg" onload="x()"><script>x()</script><image href="https://example.com/a.png"/></svg>');
    const r = py("self_check.py", bad);
    expect(r.code).toBe(1);
    for (const w of ["<script>", "onload", "remote reference", "role=img"]) expect(r.out).toContain(w);
    rmSync(dir, { recursive: true });
  });
});
