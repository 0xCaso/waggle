import { ICON_LINK, LOGO, STYLE } from "./page";

// The sign-in, link and connect pages. They use the case page's styles and self-hosted fonts.
// All dynamic text is escaped here or set with textContent in the small script.

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function authHeaders(nonce?: string): HeadersInit {
  const script = nonce ? `'nonce-${nonce}'` : "'none'";
  return {
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": `default-src 'self'; script-src ${script}; style-src 'unsafe-inline'; font-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
    "cache-control": "no-store",
    "x-frame-options": "DENY",
    "referrer-policy": "same-origin",
  };
}

const EXTRA = `
.gate .or{color:var(--mute);font-size:12px;text-align:center}
.gate .code{font:600 22px/1 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.08em;text-align:center;padding:12px;border-radius:12px;background:var(--side)}
.gate .btns{display:flex;gap:8px}
.gate .btns .primary{flex:1}
.ghost{height:32px;border:1px solid var(--line);border-radius:12px;background:#fff;color:var(--ink2);font-weight:600;font-size:12.5px;padding:0 14px;text-decoration:none;display:inline-flex;align-items:center;justify-content:center}
.ghost:hover{background:#F0F0F0}
.gate a.primary{display:inline-flex;align-items:center;justify-content:center;text-decoration:none}
.gate h3{margin:8px 0 0;font-size:12px;font-weight:650;color:var(--mute);text-transform:uppercase;letter-spacing:.04em}
.gate ul.cases{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:12px;overflow:hidden}
.gate ul.cases li{border-top:1px solid var(--line)}
.gate ul.cases li:first-child{border-top:0}
.gate ul.cases a{display:flex;flex-direction:column;gap:2px;padding:10px 12px;color:var(--ink);text-decoration:none}
.gate ul.cases a:hover{background:var(--list)}
.gate ul.cases .t{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.gate ul.cases .m{color:var(--mute);font-size:12px}
.gate .none{color:var(--mute);font-size:13px}
.gate .stack{display:flex;flex-direction:column;gap:12px}
.gate [hidden]{display:none}
.gate .done{align-items:center;text-align:center}
.gate .done .tick{width:44px;height:44px;border-radius:999px;background:var(--green-soft);color:var(--green);display:flex;align-items:center;justify-content:center}
.gate .done .primary{width:100%}
.gate .small{color:var(--mute);font-size:12px;margin:0}

.top:has(.acct){flex-wrap:nowrap}.top:has(.acct) h1{flex:1 1 auto;white-space:nowrap}
.top .acct{margin-left:auto;display:flex;align-items:center;gap:10px;min-width:0}
.acct .av{flex:none;width:28px;height:28px;border-radius:999px;background:var(--honey-soft);color:var(--ink);display:grid;place-items:center;font-weight:650;font-size:12.5px;text-transform:uppercase}
.acct .em{color:var(--ink2);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.acct .out{border:0;background:none;padding:4px 8px;border-radius:8px;color:var(--mute);font-weight:600;font-size:12.5px;transition:background-color .12s ease-out,color .12s ease-out}
.acct .out:hover:not(:disabled){background:var(--side);color:var(--ink)}
.acct .out:disabled{opacity:.4}
.home{width:100%;max-width:720px;margin:0 auto;padding:40px 20px 32px;display:flex;flex-direction:column;gap:24px;flex:1}
.home .hd h2{margin:0;font-size:28px;font-weight:600;letter-spacing:-.03em;line-height:1.15}
.home .hd p{margin:6px 0 0;color:var(--mute);font-size:13.5px}
.home .sec{background:#fff;border:1px solid var(--line);border-radius:16px;overflow:hidden}
.home .sec-h{display:flex;align-items:center;gap:8px;padding:14px 16px;border-bottom:1px solid var(--line)}
.home .sec-h h3{margin:0;font-size:14px;font-weight:650}
.home .count{display:inline-grid;place-items:center;min-width:22px;height:20px;padding:0 7px;border-radius:999px;background:var(--side);color:var(--ink2);font-size:12px;font-weight:600}
.home ul.cases{list-style:none;margin:0;padding:0}
.home ul.cases li{border-top:1px solid var(--line)}
.home ul.cases li:first-child{border-top:0}
.home ul.cases a{display:flex;align-items:center;gap:12px;padding:12px 16px;color:var(--ink);text-decoration:none;transition:background-color .12s ease-out}
.home ul.cases a:hover{background:var(--list)}
.home ul.cases .tx{flex:1;min-width:0;display:flex;flex-direction:column;gap:3px}
.home ul.cases .t{font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.home ul.cases .m{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;color:var(--mute);font-size:12.5px}
.home ul.cases .m span{display:inline-flex;align-items:center;gap:4px}
.home ul.cases .m svg,.home ul.cases .chev{flex:none}
.home ul.cases .chev{color:var(--mute);transition:transform .12s ease-out}
.home ul.cases a:hover .chev{transform:translateX(2px);color:var(--ink)}
.home .none{display:flex;flex-direction:column;align-items:center;gap:10px;padding:32px 20px;text-align:center;color:var(--mute);font-size:13.5px}
.home .none .ic{width:40px;height:40px;border-radius:999px;background:var(--side);color:var(--mute);display:grid;place-items:center}
.home .none p{margin:0;max-width:360px}
.home .foot{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;color:var(--mute);font-size:12.5px;margin-top:4px}
.home .foot a{color:var(--ink2);text-decoration:none;font-weight:500}
.home .foot a:hover{color:var(--ink);text-decoration:underline}
.home .foot .sp{flex:1}
.home .err{text-align:center}
@media (max-width:480px){.home{padding:24px 14px 24px;gap:20px}.home .hd h2{font-size:24px}.acct .em{display:none}.home ul.cases a{padding:12px}}
@media (prefers-reduced-motion:reduce){.home ul.cases .chev{transition:none}}
`;

function shell(title: string, inner: string, nonce?: string, script = "", account = "", wide = false): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Waggle</title>${ICON_LINK}<style>${STYLE}${EXTRA}</style></head><body>
<header class="top">${LOGO}<h1>Waggle</h1>${account}</header>
${wide ? `<main class="home">${inner}</main>` : `<div class="gate">${inner}</div>`}${script ? `<script nonce="${nonce}">${script}</script>` : ""}</body></html>`;
}

export function messagePage(title: string, message: string): string {
  return shell(title, `<h2>${esc(title)}</h2><p>${esc(message)}</p>`);
}

// The sign-in page: an email field, and Google when the relay has the keys for it.
export function signInPage(nonce: string, next: string, google: boolean, intro = "We send you a link. No password."): string {
  const g = google ? `<a class="ghost" href="/api/auth/google/start?next=${encodeURIComponent(next)}">Continue with Google</a><div class="or">or</div>` : "";
  const inner = `<h2>Sign in to Waggle</h2><p>${esc(intro)}</p>${g}
<form id="f" style="display:flex;flex-direction:column;gap:8px"><input id="email" type="email" placeholder="you@company.com" autocomplete="email" required>
<div class="err" id="err"></div><button class="primary" id="go">Email me a sign-in link</button></form>`;
  const script = `(function(){var NEXT=${JSON.stringify(next)};var f=document.getElementById("f"),e=document.getElementById("email"),err=document.getElementById("err"),go=document.getElementById("go");
f.addEventListener("submit",function(ev){ev.preventDefault();go.disabled=true;err.textContent="";
fetch("/api/auth/email",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json"},body:JSON.stringify({email:e.value,next:NEXT})})
.then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||"Something went wrong");return j})})
.then(function(){var g=document.querySelector(".gate");g.replaceChildren();var h=document.createElement("h2");h.textContent="Check your email";var p=document.createElement("p");p.textContent="If "+e.value+" can sign in, a link is on its way. It works once, for 15 minutes.";g.append(h,p)})
.catch(function(x){err.textContent=x.message;go.disabled=false})});e.focus()})();`;
  return shell("Sign in", inner, nonce, script);
}

// The page an email link opens. It posts by itself (a mail scanner that only fetches the link signs nobody in),
// and has a button when scripts are off.
export function linkPage(nonce: string, token: string): string {
  const inner = `<h2>Sign in to Waggle</h2><p>One click and you are in.</p>
<form id="f" method="post" action="/signin/${esc(token)}"><button class="primary" style="width:100%">Sign in</button></form>`;
  return shell("Sign in", inner, nonce, `document.getElementById("f").submit();`);
}

// Asks the person to connect a Mac. After Connect, the same page shows the result: what is connected, as whom,
// and the way back to the app.
export function connectPage(nonce: string, label: string, userCode: string, email: string): string {
  const inner = `<div id="ask" class="stack"><h2>Connect ${esc(label)} to your Waggle account?</h2><p>You are signed in as ${esc(email)}. This Mac will share cases as you.</p>
<div class="code">${esc(userCode)}</div><div class="err" id="err"></div>
<div class="btns"><button class="primary" id="ok">Connect</button><a class="ghost" href="/">Cancel</a></div></div>
<div id="done" class="stack done" hidden><div class="tick" aria-hidden="true"><svg viewBox="0 0 24 24" width="22" height="22"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg></div>
<h2>${esc(label)} is connected</h2><p>Waggle on this Mac now shares cases as ${esc(email)}. Go back to Waggle to share your case.</p>
<a class="primary" href="waggle://">Back to Waggle</a><p class="small">You can close this tab.</p></div>`;
  const script = `(function(){var ok=document.getElementById("ok"),err=document.getElementById("err");
ok.addEventListener("click",function(){ok.disabled=true;err.textContent="";
fetch("/api/auth/device/approve",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json"},body:JSON.stringify({user_code:${JSON.stringify(userCode)}})})
.then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||"Something went wrong");return j})})
.then(function(){document.getElementById("ask").hidden=true;document.getElementById("done").hidden=false;document.title="Connected · Waggle"})
.catch(function(x){err.textContent=x.message;ok.disabled=false})})})();`;
  return shell("Connect", inner, nonce, script);
}

export type HomeCase = {
  id: string;
  title: string;
  mode: string;
  comment_count: number;
  created_at?: number;
  last_at?: number;
  owner_email?: string | null;
};

const SVG = (inner: string, size = 14) =>
  `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
const GLOBE = SVG('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.6 2.7 3.9 5.7 3.9 9s-1.3 6.3-3.9 9c-2.6-2.7-3.9-5.7-3.9-9S9.4 5.7 12 3z"/>');
const PEOPLE = SVG('<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5M16 5.2a3.2 3.2 0 0 1 0 5.6M18 14.8c1.8.7 3 2.5 3 5.2"/>');
const CHAT = SVG('<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>');
const CHEV = SVG('<path d="M9 6l6 6-6 6"/>', 16).replace("<svg ", '<svg class="chev" ');
const LINK_IC = SVG('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>', 20);
const INBOX_IC = SVG('<path d="M3 13l3-8h12l3 8v6H3z"/><path d="M3 13h5l1 3h6l1-3h5"/>', 20);

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function day(ms: number): string {
  const d = new Date(ms);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

// "Updated 2 h ago" when the case changed after it was shared, else "Shared 18 Oct".
export function whenText(c: HomeCase, now: number): string {
  const created = c.created_at;
  const last = c.last_at;
  if (last && created && last > created) {
    const mins = Math.max(0, Math.floor((now - last) / 60000));
    if (mins < 1) return "Updated just now";
    if (mins < 60) return `Updated ${mins} min ago`;
    if (mins < 60 * 24) return `Updated ${Math.floor(mins / 60)} h ago`;
    if (mins < 60 * 24 * 7) return `Updated ${Math.floor(mins / 1440)} d ago`;
    return `Updated ${day(last)}`;
  }
  return created ? `Shared ${day(created)}` : "";
}

function caseList(rows: HomeCase[], empty: string, icon: string, now: number, showOwner: boolean): string {
  if (rows.length === 0) return `<div class="none"><div class="ic">${icon}</div><p>${esc(empty)}</p></div>`;
  const items = rows.map((c) => {
    const n = c.comment_count === 1 ? "1 comment" : `${c.comment_count} comments`;
    const who = c.mode === "emails" ? `<span>${PEOPLE}Only listed people</span>` : `<span>${GLOBE}Anyone with the link</span>`;
    const from = showOwner && c.owner_email ? `<span>from ${esc(c.owner_email.split("@")[0])}</span>` : "";
    const when = whenText(c, now);
    return `<li><a href="/d/${encodeURIComponent(c.id)}"><span class="tx"><span class="t">${esc(c.title)}</span><span class="m">${who}${from}<span>${CHAT}${n}</span>${when ? `<span>${esc(when)}</span>` : ""}</span></span>${CHEV}</a></li>`;
  });
  return `<ul class="cases">${items.join("")}</ul>`;
}

function section(title: string, rows: HomeCase[], list: string): string {
  return `<section class="sec"><div class="sec-h"><h3>${esc(title)}</h3><span class="count">${rows.length}</span></div>${list}</section>`;
}

// Where a person lands after signing in on the web: who they are, their cases, and sign out.
export function homePage(nonce: string, email: string, mine: HomeCase[], shared: HomeCase[], now = Date.now()): string {
  const account = `<div class="acct"><span class="av" aria-hidden="true">${esc([...email][0] ?? "")}</span><span class="em">${esc(email)}</span><button class="out" id="out">Sign out</button></div>`;
  const inner = `<div class="hd"><h2>Your cases</h2><p>Cases you share from Waggle on your Mac, and cases people share with you.</p></div>
${section("Shared by you", mine, caseList(mine, "You have not shared a case yet. Open a case in Waggle on your Mac and choose Share.", LINK_IC, now, false))}
${section("Shared with you", shared, caseList(shared, "Nobody has shared a case with you yet.", INBOX_IC, now, true))}
<div class="err" id="err"></div>
<footer class="foot"><a href="waggle://">Open Waggle on your Mac</a><span class="sp"></span><a href="https://waggle.so/privacy">Privacy</a><a href="https://waggle.so/terms">Terms</a></footer>`;
  const script = `(function(){var b=document.getElementById("out"),err=document.getElementById("err");
b.addEventListener("click",function(){b.disabled=true;fetch("/api/auth/signout",{method:"POST",credentials:"same-origin"})
.then(function(r){if(!r.ok)throw new Error("Could not sign out. Try again.");location.href="/signin"})
.catch(function(x){err.textContent=x.message;b.disabled=false})})})();`;
  return shell("Home", inner, nonce, script, account, true);
}
