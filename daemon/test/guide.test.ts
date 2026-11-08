import { describe, expect, test } from "bun:test";
import { getGuide, guideIndex, guideTopics } from "../src/guide";

// Pulls the text of a "## heading" section (up to the next "## " heading, or
// end of file) out of a guide's markdown, so a test can check one section
// without matching against the whole document.
function extractSection(content: string, heading: string): string {
  const start = content.indexOf(heading);
  if (start === -1) throw new Error(`heading "${heading}" not found`);
  const rest = content.slice(start);
  const next = rest.indexOf("\n## ", heading.length);
  return next === -1 ? rest : rest.slice(0, next);
}

// Pulls the indented ```<!doctype html> ... </html>``` code block out of a
// markdown section (this repo's guides use 4-space indented code blocks, not
// fenced ones) so a test can parse it as real HTML.
function extractIndentedHtmlBlock(section: string): string {
  const lines = section.split("\n");
  const start = lines.findIndex((line) => line.trim() === "<!doctype html>");
  if (start === -1) throw new Error("no <!doctype html> block found");
  const htmlLines: string[] = [];
  for (let i = start; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "") {
      htmlLines.push("");
      continue;
    }
    if (!line.startsWith("    ")) break;
    htmlLines.push(line.slice(4));
    if (line.trim() === "</html>") break;
  }
  return htmlLines.join("\n");
}

// HAIL-38: the waggle_guide tool serves these directly (test/mcp.test.ts drives
// it end to end); this file pins the module's own contract - every topic in
// the index actually loads, and an unknown topic names the valid ones.
describe("guide", () => {
  test("taste, plan and artifacts hold the flow-first block", () => {
    for (const topic of ["taste", "plan", "artifacts"]) {
      const text = getGuide(topic) ?? "";
      expect(text).toContain("Flow first, then screens. Order: 1) goal and who uses it, 2) user flows: the steps, what comes first and why, 3) the order of screens from the flow, 4) screen detail.");
    }
  });

  test("guideTopics lists the topics the contract names", () => {
    expect(guideTopics()).toEqual([
      "writing-an-ask",
      "artifacts",
      "taste",
      "bundle-fonts",
      "plan",
      "reviews",
      "after-the-reply",
      "team-comments",
      "starter-prompts",
      "design-kit",
      "project",
      "decision-record",
      "whats-new",
    ]);
  });

  test("the artifacts guide says when to use the optional impeccable skill (HAIL-239)", () => {
    const content = getGuide("artifacts").replace(/\s+/g, " ");
    expect(content).toContain("If the impeccable skill is available, use it at these moments");
    for (const cmd of ["`shape`", "`polish`", "`critique`", "`audit`", "`harden`"]) expect(content).toContain(cmd);
  });

  test("the index lists every topic and a reason to read it", () => {
    const index = guideIndex();
    for (const topic of guideTopics()) {
      expect(index).toContain(topic);
    }
  });

  test("every topic in the index actually loads non-empty content", () => {
    for (const topic of guideTopics()) {
      const content = getGuide(topic);
      expect(content.length).toBeGreaterThan(0);
      expect(content).toContain("WRONG");
      expect(content).toContain("right");
    }
  });

  // HAIL-103: pins stay on the view they were made on.
  test("update guidance says a message-only update keeps the old artifact (HAIL-146)", () => {
    for (const topic of ["after-the-reply", "artifacts"] as const) {
      const content = getGuide(topic).replace(/\s+/g, " ");
      expect(content).toContain("send a new artifact with it");
      expect(content).toContain("An update with only a message keeps the old artifact on screen");
    }
  });

  test("artifacts tells prototypes to give each view a hash", () => {
    const content = getGuide("artifacts").replace(/\s+/g, " ");
    expect(content).toContain(
      "Give each tab, variant or step its own #address (location.hash) and render from it on hashchange, so the human's comments stay on the view they were made on.",
    );
    expect(content).toContain("Tabs, variants and steps in a prototype");
  });

  // HAIL-44: change an ask you already sent, instead of leaving it open.
  test("writing-an-ask covers replaces", () => {
    const content = getGuide("writing-an-ask");
    expect(content).toContain("replaces");
    expect(content).toContain("never leave the old one open");
  });

  // HAIL-48 amendment A1: agent-facing changes per version, served live.
  test("whats-new covers 0.1.9's open schemas", () => {
    const content = getGuide("whats-new");
    expect(content).toContain("0.1.9");
    expect(content).toContain("accept fields beyond the ones your session saw at start");
  });

  // HAIL-237: design taste for artifacts, alone and inside the artifacts guide.
  test("taste is a topic, is in the artifacts guide, and stays short", () => {
    const taste = getGuide("taste");
    expect(taste.trimEnd().split("\n").length).toBeLessThanOrEqual(25);
    expect(taste).toContain("100 to 150 ms");
    expect(taste).toContain("A design kit in this guide wins");
    expect(getGuide("artifacts")).toContain(taste.trimEnd());
    expect(taste).not.toContain("—");
  });

  test("artifacts covers choosing the type and both templates", () => {
    const content = getGuide("artifacts");
    expect(content).toContain("markdown");
    expect(content).toContain("html_bundle");
    expect(content).toContain("640px");
    expect(content).toContain("<style>");
  });

  // HAIL-49: a real preview for an html_bundle - what makes one good, and a
  // ready preview.html template - plus viewport for sizing the fallback
  // render instead.
  test("artifacts covers a good preview and gives a ready preview.html template", () => {
    const content = getGuide("artifacts");
    expect(content).toContain("## Give your html_bundle a preview");
    expect(content).toContain("never a screenshot of the page");
    expect(content).toContain('preview: "preview.html"');
    expect(content).toContain("500 to 1100 px");
    expect(content).toContain("280 px");
    expect(content).toContain("no scrolling");

    const section = extractSection(content, "## Give your html_bundle a preview");
    const html = extractIndentedHtmlBlock(section);
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("</html>");
    expect(html).not.toMatch(/https?:\/\//);
  });

  test("artifacts covers viewport for sizing the fallback render", () => {
    const content = getGuide("artifacts");
    expect(content).toContain("## Sizing the render for a phone or other viewport");
    expect(content).toContain('viewport: { width: 390, height: 844 }');
  });

  test("artifacts has a gallery section with a valid, self-contained HTML template", async () => {
    const content = getGuide("artifacts");
    expect(content).toContain("## Several screenshots: a gallery page");
    expect(content).toContain("sips -Z 1400");
    expect(content).toContain('artifact: { type: "html_bundle", dir: "./proto/gallery", entry: "index.html" }');

    const section = extractSection(content, "## Several screenshots: a gallery page");
    const html = extractIndentedHtmlBlock(section);

    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("</html>");
    expect(html).not.toMatch(/https?:\/\//);
    expect(html).not.toMatch(/<script[^>]*\ssrc=/i);

    const imgSrcs: string[] = [];
    const scriptSrcs: string[] = [];
    const rewriter = new HTMLRewriter();
    rewriter.on("img", {
      element(el) {
        imgSrcs.push(el.getAttribute("src") ?? "");
      },
    });
    rewriter.on("script", {
      element(el) {
        const src = el.getAttribute("src");
        if (src) scriptSrcs.push(src);
      },
    });
    await rewriter.transform(new Response(html)).text();

    expect(imgSrcs.length).toBeGreaterThan(0);
    expect(scriptSrcs).toEqual([]);
    for (const src of imgSrcs) {
      expect(src).not.toMatch(/^https?:\/\//);
      expect(src.startsWith("/")).toBe(false);
      expect(src).not.toContain("..");
    }
  });

  test("an unknown topic throws an error listing every valid topic", () => {
    expect(() => getGuide("nope")).toThrow('Unknown guide topic "nope"');
    try {
      getGuide("nope");
      throw new Error("expected getGuide to throw");
    } catch (err) {
      for (const topic of guideTopics()) {
        expect((err as Error).message).toContain(topic);
      }
    }
  });
});
