// The sample review artifact for `waggle test-ask`: the pricing-card fixture
// (docs/stories/HAIL-29.md O6: "The test-ask fixture becomes the pricing
// card (A compact / B detailed) instead of the checkout"). It is embedded as
// string constants so the compiled `knock` binary can stage it without
// shipping the source tree. daemon/test/cli.test.ts asserts these strings
// equal the files under daemon/test/fixtures/pricing-card, so the two
// cannot drift.

export const TEST_FIXTURE = {
  "index.html": `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Pricing card</title>
    <link rel="stylesheet" href="style.css" />
  </head>
  <body>
    <main class="layouts">
      <section class="card" id="card-a" data-layout="a">
        <div class="head">
          <span class="label">A · Compact</span>
          <span class="tag">Recommended</span>
        </div>
        <p class="plan">Pro</p>
        <p class="price">$12<span>/mo</span></p>
        <button type="button" class="cta">Choose Pro</button>
      </section>

      <section class="card wide" id="card-b" data-layout="b">
        <div class="head">
          <span class="label">B · Detailed</span>
        </div>
        <p class="plan">Pro</p>
        <p class="price">$12<span>/mo</span></p>
        <ul class="features">
          <li>Unlimited projects</li>
          <li>Priority support</li>
        </ul>
        <button type="button" class="cta">Choose Pro</button>
      </section>
    </main>

    <p class="note" id="note">A local prototype for artifact staging tests.</p>

    <script src="app.js"></script>
  </body>
</html>
`,
  "style.css": `:root {
  color-scheme: light dark;
}

body {
  margin: 0;
  font-family: system-ui, -apple-system, sans-serif;
  background: #f6f6f6;
  color: #1a1a1a;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 48px 16px;
}

.layouts {
  display: flex;
  gap: 16px;
}

.card {
  width: 160px;
  background: #ffffff;
  border-radius: 10px;
  padding: 16px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.08);
}

.card.wide {
  width: 200px;
}

.head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  margin-bottom: 8px;
}

.label {
  font-size: 12px;
  font-weight: 600;
}

.tag {
  font-size: 10px;
  font-weight: 600;
  color: #b34a24;
  background: #fbe8e0;
  border-radius: 4px;
  padding: 2px 6px;
}

.plan {
  margin: 0;
  font-size: 18px;
  font-weight: 700;
}

.price {
  margin: 2px 0 12px;
  font-size: 15px;
  font-weight: 600;
}

.price span {
  font-size: 12px;
  font-weight: 400;
  color: #666;
}

.features {
  list-style: none;
  margin: 0 0 12px;
  padding: 0;
  font-size: 12px;
}

.features li {
  padding: 2px 0;
}

.features li::before {
  content: "✓ ";
  color: #0a7d32;
}

.cta {
  width: 100%;
  padding: 8px;
  border: none;
  border-radius: 6px;
  background: #1a1a1a;
  color: #ffffff;
  font-size: 13px;
  cursor: pointer;
}

.note {
  margin: 20px 0 0;
  font-size: 13px;
  color: #666;
}

@media (prefers-color-scheme: dark) {
  body {
    background: #161616;
    color: #f6f6f6;
  }

  .card {
    background: #232323;
  }

  .cta {
    background: #f6f6f6;
    color: #161616;
  }
}
`,
  "app.js": `"use strict";

// A tiny pricing-card prototype: choosing Pro on either layout confirms in
// place. No network, no external URLs.
const buttons = document.querySelectorAll(".cta");
const note = document.getElementById("note");

for (const button of buttons) {
  button.addEventListener("click", () => {
    const card = button.closest(".card");
    const layout = card ? card.dataset.layout : "?";
    note.textContent = \`Chose Pro on layout \${layout}. This prototype takes no payment.\`;
  });
}
`,
};
