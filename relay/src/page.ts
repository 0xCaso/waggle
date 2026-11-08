// The shared case page. All data comes from /api/cases/<id>/state and is set with
// textContent, never as HTML. The artifact runs in a sandboxed frame from the content origin.

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// The Waggle mark (the site's logo: a honey hexagon with a white W) and the same mark as the tab icon.
export const LOGO = `<svg class="mark" viewBox="0 0 100 100" width="22" height="22" aria-hidden="true"><defs><linearGradient id="wg-honey" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F9C846"/><stop offset="1" stop-color="#E89A0C"/></linearGradient></defs><path d="M50 0 L93.3 25 L93.3 75 L50 100 L6.7 75 L6.7 25 Z" fill="url(#wg-honey)"/><path d="M27 40 L38 63 L50 43 L62 63 L73 40" fill="none" stroke="#fff" stroke-width="9" stroke-linejoin="round" stroke-linecap="round"/></svg>`;
const ICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="M50 0 L93.3 25 L93.3 75 L50 100 L6.7 75 L6.7 25 Z" fill="#F2B01E"/><path d="M27 40 L38 63 L50 43 L62 63 L73 40" fill="none" stroke="#fff" stroke-width="10" stroke-linejoin="round" stroke-linecap="round"/></svg>`;
export const ICON_LINK = `<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,${encodeURIComponent(ICON_SVG)}">`;

export const STYLE = `
@font-face{font-family:"Inter Tight";src:url(/fonts/inter-tight.woff2) format("woff2");font-weight:100 900;font-style:normal;font-display:swap}
@font-face{font-family:"JetBrains Mono";src:url(/fonts/jetbrains-mono.woff2) format("woff2");font-weight:100 800;font-style:normal;font-display:swap}
:root{--honey:#F2B01E;--honey-soft:#FDF4DA;--ink:#16181A;--ink2:#4A4C50;--mute:#6B6B6B;--line:#E6E6E6;--list:#FAFAFA;--side:#F3F3F3;--red:#E0352B;--green:#18A058;--green-soft:#E3F5EA;color-scheme:light}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{margin:0;height:100%}
body{overflow-wrap:break-word}
body{font:13.5px/1.5 "Inter Tight",-apple-system,system-ui,sans-serif;color:var(--ink);background:var(--list);-webkit-font-smoothing:antialiased}
button,input,textarea{font:inherit;color:var(--ink);background:#fff}
button{cursor:pointer}
.top{display:flex;align-items:center;gap:10px;padding:14px 20px;border-bottom:1px solid var(--line);background:#fff}
.mark{width:22px;height:22px;flex:none;display:block}
h1{font-size:17px;font-weight:600;letter-spacing:-.02em;margin:0;text-wrap:balance;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chip{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:999px;background:var(--side);color:var(--ink2);font-size:12.5px;font-weight:500;white-space:nowrap}
.chip.you{background:var(--honey-soft)}
body{display:flex;flex-direction:column}
#app{flex:1;min-height:0;display:flex;flex-direction:column}
.wrap{display:grid;grid-template-columns:minmax(0,1fr) 340px;grid-template-rows:minmax(0,1fr);grid-auto-rows:0;flex:1;min-height:0}
.main{display:flex;flex-direction:column;min-width:0;min-height:0;padding:12px 16px 16px;gap:10px}
.tool{flex:none;display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 12px;border-radius:999px;border:1px solid var(--line);background:#fff;color:var(--ink2);font-size:12.5px;font-weight:500;white-space:nowrap;transition:background-color .12s ease-out,transform .12s ease-out}
.tool:hover{background:#F0F0F0}
:where(button,a,[tabindex]):focus-visible{outline:2px solid var(--honey);outline-offset:2px}
textarea:focus-visible,input:focus-visible{outline:none;box-shadow:0 0 0 3px rgba(242,176,30,.25)}.tool:active{transform:scale(.97)}
.tool[aria-pressed=true]{background:var(--ink);border-color:var(--ink);color:#fff}
.tool svg{width:14px;height:14px}
.area{display:inline-flex;align-items:center;gap:6px;margin:6px 0 0;padding:3px 8px;border:0;border-radius:999px;background:var(--honey-soft);color:var(--ink2);font-size:12px;font-weight:500;max-width:100%;min-width:0;text-align:left;transition:background-color .12s ease-out,transform .12s ease-out}
.area:hover{background:#FBEAB8}.area:active{transform:scale(.97)}
.area b{flex:none;display:inline-grid;place-items:center;min-width:18px;height:18px;padding:0 4px;border-radius:9px;background:var(--ink);color:#fff;font-size:10.5px}
.area span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.frame{flex:1;min-height:240px;min-width:0;border:1px solid var(--line);border-radius:12px;background:#fff;overflow:hidden}
.frame iframe{width:100%;height:100%;border:0;display:block}
.slot:empty,.fab{display:none}
.askwrap{flex:none;display:flex;flex-direction:column;gap:10px}
.askbar{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;min-height:44px;padding:6px 8px 6px 14px;border:1px solid #F3DFA3;border-radius:12px;background:var(--honey-soft);min-width:0}
.askbar.done{background:var(--green-soft);border-color:#BFE5CD}
.askbar svg{flex:none;width:18px;height:18px;color:#B87A00}
.askbar.done svg{color:var(--green)}
.askbar .q{flex:1 1 220px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.askbar.done .q{color:#0E6B3A}
.pill{flex:none;display:inline-flex;align-items:center;height:22px;padding:0 9px;border-radius:999px;background:#fff;border:1px solid #F0DFAE;font-size:12px;font-weight:500;color:var(--ink2);white-space:nowrap}
.askbar .rec1{flex:0 1 auto;min-width:0;max-width:30%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--mute);font-size:12.5px}
.askbar .primary{margin-left:auto}
.tb{flex:none;display:flex;align-items:center;flex-wrap:wrap;gap:8px;min-width:0}
.tb .l,.tb .r{display:flex;align-items:center;flex-wrap:wrap;gap:8px;min-width:0}
.tb .r{margin-left:auto}
.xmark{display:none;align-items:center}
.rchip{display:inline-flex;align-items:center;gap:8px;height:32px;padding:0 12px;border-radius:12px;background:var(--ink);color:#fff;font-weight:600;font-size:12.5px;max-width:100%;min-width:0}
.rchip>span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.latest{flex:none;display:inline-flex;align-items:center;height:18px;padding:0 7px;border-radius:999px;background:var(--honey);color:var(--ink);font-size:10.5px;font-weight:700;font-style:normal}
.btn{display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 12px;border:1px solid var(--line);border-radius:12px;background:#fff;color:var(--ink2);font-size:12.5px;font-weight:500;white-space:nowrap;transition:background-color .12s ease-out,transform .12s ease-out}
.btn:hover{background:#F0F0F0}.btn:active{transform:scale(.97)}
.btn[aria-pressed=true]{background:var(--ink);border-color:var(--ink);color:#fff}
.btn svg{width:14px;height:14px;flex:none}
.btn kbd{font:600 10.5px/1 "JetBrains Mono",ui-monospace,monospace;padding:3px 5px;border-radius:5px;background:rgba(255,255,255,.14);color:inherit}
.dd{position:relative}
.menu{position:absolute;left:0;top:calc(100% + 6px);z-index:30;width:320px;max-width:calc(100vw - 32px);max-height:60vh;overflow:auto;background:#fff;border:1px solid var(--line);border-radius:12px;box-shadow:0 8px 24px rgba(22,24,26,.14);padding:6px;transform-origin:top left;animation:pop .2s ease-out}
@keyframes pop{from{opacity:0;transform:scale(.97)}to{opacity:1;transform:none}}
.menu .mh{font:600 10.5px/1 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.06em;text-transform:uppercase;color:var(--mute);padding:8px 8px 6px}
.mi{display:flex;align-items:center;gap:10px;width:100%;padding:7px 8px;border:0;border-radius:8px;background:none;text-align:left}
.mi:hover,.mi:focus-visible{background:var(--list)}
.mi .n{flex:none;display:grid;place-items:center;width:24px;height:24px;border-radius:6px;background:var(--side);font-size:12px;font-weight:600}
.mi[aria-checked=true] .n{background:var(--honey)}
.mi .t{flex:1;min-width:0;display:flex;flex-direction:column}
.mi .nm{display:flex;align-items:center;gap:6px;font-weight:600;min-width:0}
.mi .nm>span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mi small{color:var(--mute);font-size:12px}
.mi svg{flex:none;width:14px;height:14px;color:var(--ink)}
.late{flex:none;display:flex;align-items:center;flex-wrap:wrap;gap:6px 10px;padding:5px 6px 5px 12px;border-radius:12px;background:var(--honey-soft);border:1px solid #F3DFA3;color:var(--ink2);font-size:12.5px}
.late span{flex:1 1 200px;min-width:0}
.late .btn{height:26px;padding:0 10px;font-size:12px}
.icon{display:inline-grid;place-items:center;width:28px;height:28px;border:0;border-radius:8px;background:none;color:var(--mute);padding:0}
.icon:hover{background:rgba(22,24,26,.06)}.icon svg{width:15px;height:15px}
.rail{align-items:center;gap:10px;padding-top:10px}
.rail .icon{width:32px;height:32px}
.rail b{font-size:12px;font-weight:600;color:var(--ink2)}
.fab{position:fixed;right:20px;bottom:20px;z-index:1005;align-items:center;gap:8px;height:40px;padding:0 16px;border:0;border-radius:999px;background:var(--ink);color:#fff;font-weight:600;font-size:13px;box-shadow:0 6px 20px rgba(22,24,26,.3)}
.fab svg{width:15px;height:15px}
.xonly{display:none}
body.lock{overflow:hidden}
.wrap.xp{position:fixed;inset:0;z-index:1000;display:flex;flex-direction:column;height:auto;flex:none;background:var(--list)}
.xp .main{flex:1;padding:0;gap:0;min-height:0}
.xp .slot-ask,.xp .nox{display:none}
.xp .xonly{display:inline-flex}
.xp .tb{padding:8px 16px;background:var(--ink)}
.xp .tb .btn{background:transparent;border-color:rgba(255,255,255,.22);color:#fff}
.xp .tb .btn:hover{background:rgba(255,255,255,.1)}
.xp .tb .btn[aria-pressed=true]{background:#fff;color:var(--ink)}
.xp .rchip{background:#2C2E31}
.xp .frame{flex:1;min-height:0;border:0;border-radius:0}
.xp .late{border-radius:0;border-width:1px 0}
.xp .fab{display:inline-flex}
.xp.pan .fab{display:none}
.xp .side{position:fixed;top:0;right:0;bottom:0;width:min(380px,100vw);z-index:1010;border-left:1px solid var(--line);box-shadow:-8px 0 24px rgba(22,24,26,.16);transform:translateX(100%);visibility:hidden;transition:transform .22s ease-out,visibility 0s linear .22s}
.xp.pan .side{transform:none;visibility:visible;transition-delay:0s}
.wrap.folded{grid-template-columns:minmax(0,1fr) 40px}
@media (prefers-reduced-motion:reduce){.menu{animation:none}.xp .side{transition:none}}
.side{border-left:1px solid var(--line);background:#fff;display:flex;flex-direction:column;min-height:0;min-width:0}
.label{font:600 10.5px/1 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.06em;text-transform:uppercase;color:var(--mute);padding:16px 16px 8px}
.list{flex:1;overflow-y:auto;padding:12px 12px 16px;display:flex;flex-direction:column;gap:8px;min-width:0}
.c{border:1px solid var(--line);border-radius:16px;padding:10px 12px;min-width:0}
.c .who{display:flex;gap:6px;align-items:center;font-size:12.5px;font-weight:600}
.c .who small{font-weight:500;color:var(--mute)}
.c blockquote{margin:6px 0;overflow-wrap:anywhere;padding:4px 8px;border-left:3px solid var(--honey);background:var(--honey-soft);border-radius:4px;color:var(--ink2);font-size:12.5px}
.c p{margin:4px 0 0;color:var(--ink2);white-space:pre-wrap;overflow-wrap:anywhere}
.empty{color:var(--mute);padding:6px 4px}
.compose{border-bottom:1px solid var(--line);padding:0 12px 12px;display:flex;flex-direction:column;gap:8px}
.quote{display:none;align-items:flex-start;gap:6px;font-size:12.5px;color:var(--ink2);background:var(--honey-soft);border-radius:8px;padding:6px 8px}
.quote.on{display:flex}
.quote span{flex:1;min-width:0;overflow:hidden;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical}
.quote.q-text span{border-left:3px solid var(--honey);padding-left:8px;font-style:italic}
.quote button{position:relative;flex:none;display:grid;place-items:center;width:24px;height:24px;margin:-2px -4px -2px 0;border:0;border-radius:999px;background:none;color:var(--mute);padding:0;transition:background-color .12s ease-out,transform .12s ease-out}
.quote button::after{content:"";position:absolute;inset:-10px}
.quote button:hover{background:rgba(22,24,26,.06)}.quote button:active{transform:scale(.97)}
.quote button svg{width:12px;height:12px}
textarea,input[type=text],input[type=email]{width:100%;border:1px solid var(--line);border-radius:12px;padding:8px 10px;outline:none;resize:none}
textarea{min-height:38px;max-height:104px}
textarea:focus,input:focus{border-color:var(--honey)}
.primary{height:32px;border:0;border-radius:12px;background:var(--ink);color:#fff;font-weight:600;font-size:12.5px;padding:0 14px;transition:transform .12s ease-out,opacity .12s ease-out}
.primary:hover:not(:disabled){background:#2A2C2E}.primary:active{transform:scale(.97)}.primary:disabled{opacity:.4;cursor:default}
.row{display:flex;gap:8px;align-items:center;justify-content:space-between}
.hint{color:var(--mute);font-size:12px}
.gate{max-width:380px;margin:12vh auto;background:#fff;border:1px solid var(--line);border-radius:16px;padding:24px;display:flex;flex-direction:column;gap:12px}
.gate h2{margin:0;font-size:20px;letter-spacing:-.02em}
.gate p{margin:0;color:var(--ink2)}
.err{color:var(--red);font-size:12.5px;min-height:1em}
.ask{flex:none;max-height:42vh;overflow:auto;display:flex;flex-direction:column;gap:12px}
.ask .k{font-size:10.5px;font-weight:600;line-height:1.2;letter-spacing:.06em;text-transform:uppercase;color:var(--mute)}
.rec{background:var(--side);border-radius:8px;padding:12px 16px;display:flex;flex-direction:column;gap:4px}
.rec b{font-size:13.5px;font-weight:600;overflow-wrap:anywhere}
.rec p{margin:0;font-size:12.5px;color:var(--ink2);overflow-wrap:anywhere}
.nw{display:flex;gap:32px}
.nw>div{flex:1;min-width:0;display:flex;flex-direction:column;gap:6px}
.nw p{margin:0;font-size:13.5px;overflow-wrap:anywhere}
.opts{display:flex;flex-direction:column;gap:6px}
.opt{border:1px solid var(--line);border-radius:10px;padding:8px 12px;background:#fff;min-width:0}
.opt.rc{border-color:var(--honey);background:var(--honey-soft)}
.opt b{font-weight:600;font-size:13px;overflow-wrap:anywhere}
.opt p{margin:2px 0 0;font-size:12.5px;color:var(--ink2);overflow-wrap:anywhere}
.ask.past .nw p,.ask.past .opt,.ask.past .rec{opacity:.6}
.decided{background:var(--green-soft);border-radius:8px;padding:12px 16px;display:flex;flex-direction:column;gap:4px}
.decided b{font-size:13.5px;font-weight:600;overflow-wrap:anywhere}
.decided p{margin:0;font-size:12.5px;color:var(--ink2);overflow-wrap:anywhere;white-space:pre-wrap}
.sidehead{display:flex;align-items:center;justify-content:space-between;gap:8px;padding-right:12px}
.sidehead .tool{height:24px;padding:0 10px;font-size:12px}
.note{color:var(--mute);font-size:12px;padding:0 16px 8px}
.c.done{padding:0}
.fold{display:flex;align-items:center;gap:8px;width:100%;min-width:0;border:0;background:none;padding:8px 12px;text-align:left;border-radius:16px;font-size:12.5px;color:var(--ink2)}
.fold:hover{background:#F7F7F7}
.fold .ok{flex:none;font-weight:600;color:var(--green)}
.fold .first{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fold small{flex:none;color:var(--mute)}
.c .acts{display:flex;gap:6px;align-items:center;margin-top:6px}
.lnk{border:0;background:none;padding:2px 4px;margin-left:-4px;border-radius:6px;color:var(--ink2);font-size:12px;font-weight:500;text-decoration:underline;text-underline-offset:2px}
.lnk:hover{color:var(--ink)}
.replies{margin:8px 0 0;padding-left:10px;border-left:2px solid var(--line);display:flex;flex-direction:column;gap:8px}
.reply .who{display:flex;gap:6px;align-items:center;font-size:12.5px;font-weight:600}
.reply .who small{font-weight:500;color:var(--mute)}
.reply p{margin:2px 0 0;color:var(--ink2);white-space:pre-wrap;overflow-wrap:anywhere}
.rbox{margin-top:8px;display:flex;flex-direction:column;gap:6px}
@media (max-width:800px){html,body{height:auto}body{display:block}#app{height:auto;display:block}.top{flex-wrap:wrap}h1{white-space:normal;flex-basis:calc(100% - 40px)}.wrap{grid-template-columns:minmax(0,1fr);grid-template-rows:none;grid-auto-rows:auto;height:auto;flex:none}.side{border-left:0;border-top:1px solid var(--line)}.frame{flex:none;min-height:240px}.xp .frame{flex:1;min-height:0}.list{max-height:none;overflow:visible}.ask{max-height:none}.askbar .rec1{max-width:100%}.tb .r{margin-left:0}.nw{flex-direction:column;gap:12px}}
`;

export function casePage(c: { id: string; title: string; mode: string }, nonce: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(c.title)} · Waggle</title>${ICON_LINK}<style>${STYLE}</style></head><body>
<header class="top">${LOGO}<h1 id="title">${esc(c.title)}</h1>
<span class="chip" id="mode"></span><span class="chip you" id="you" hidden></span><button class="tool" id="out" type="button" hidden>Sign out</button></header>
<div id="app"></div>
<script nonce="${nonce}">${CLIENT.replace("__CASE__", () => JSON.stringify(c.id)).replace("__LOGO__", () => JSON.stringify(LOGO))}</script></body></html>`;
}

export function notFoundPage(message = "This case is not here. The link may be wrong, or the owner removed it.", heading = "Not found"): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(heading)} · Waggle</title>${ICON_LINK}<style>${STYLE}</style></head><body><div class="gate"><h2>${esc(heading)}</h2><p>${esc(message)}</p></div></body></html>`;
}

const CLIENT = String.raw`
(function(){
var ID=__CASE__, LOGO=__LOGO__, S=null, current=null, anchor=null, frame=null, tool="text", toolBtn=null, draft="";
var replyDraft={}, replying=null, expanded={}, sig="", lastActive=Date.now(), paused=false, pendingScroll=null;
var POLL_MS=20000, IDLE_MS=30*60000, TICKET_LEFT_MS=5*60000;
var X='<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M2.5 2.5l7 7M9.5 2.5l-7 7"/></svg>';
var app=document.getElementById("app");
function el(tag,attrs,kids){var e=document.createElement(tag);for(var k in attrs||{}){if(k==="text")e.textContent=attrs[k];else if(k.slice(0,2)==="on")e.addEventListener(k.slice(2),attrs[k]);else e.setAttribute(k,attrs[k]);}(kids||[]).forEach(function(c){if(c)e.appendChild(c)});return e}
function api(path,opts){opts=opts||{};opts.headers={"content-type":"application/json"};opts.credentials="same-origin";return fetch("/api/cases/"+ID+path,opts).then(function(r){return r.json().then(function(j){if(!r.ok){var e=new Error(j.error||"Error");e.status=r.status;throw e}return j})})}
function ago(t){var s=Math.round((Date.now()-t)/1000);if(s<60)return"now";if(s<3600)return Math.floor(s/60)+" min ago";if(s<86400)return Math.floor(s/3600)+" h ago";return new Date(t).toLocaleDateString()}

function fail(e){if(e.status===401)signIn();else if(e.status===403)notListed(e.message);else if(e.status===410)gone(e.message);else app.replaceChildren(el("div",{class:"gate"},[el("h2",{text:"Something went wrong"}),el("p",{text:e.message})]))}
function load(){api("/state").then(take).catch(fail)}
// The people and the rounds decide what the page shows. The tickets in the round links change on every answer, so they stay out.
function signature(s){return JSON.stringify([s.title,s.mode,s.ask,s.status,s.decided,s.comments_closed,s.viewer,s.comments,s.rounds.map(function(r){return[r.seq,r.label,r.variant,r.ask,r.entry]})])}
function take(s){
  var next=signature(s),changed=next!==sig;
  sig=next;S=s;
  if(changed||!app.firstChild||!frame){render();return}
  refreshTicket();
}
function gone(msg){
  document.getElementById("mode").textContent="Stopped";
  app.replaceChildren(el("div",{class:"gate"},[el("h2",{text:"Stopped"}),el("p",{text:msg})]));
}

function signOut(){fetch("/api/auth/signout",{method:"POST",credentials:"same-origin"}).then(function(){location.reload()})}

// The owner shared this case with a list of emails. A person signs in with the email, by link or with Google.
function signIn(){
  document.getElementById("mode").textContent="Only listed emails";
  var go=el("a",{class:"primary",href:"/signin?next="+encodeURIComponent("/d/"+ID),text:"Sign in"});
  go.style.cssText="display:inline-flex;align-items:center;justify-content:center;text-decoration:none";
  app.replaceChildren(el("div",{class:"gate"},[el("h2",{text:"Sign in to see this case"}),el("p",{text:"The owner shared it with a list of emails. Sign in with yours."}),go]));
}

function notListed(msg){
  document.getElementById("mode").textContent="Only listed emails";
  var out=el("button",{class:"primary",text:"Sign out",onclick:signOut});
  app.replaceChildren(el("div",{class:"gate"},[el("h2",{text:"You are not on the list"}),el("p",{text:msg}),out]));
}

// A rebuild of the page keeps the focus, the caret and the scroll of the comment list.
function preserve(fn){
  var a=document.activeElement,key=a&&a.getAttribute?a.getAttribute("data-key"):null,s=a&&a.selectionStart,e=a&&a.selectionEnd;
  var l=document.querySelector(".list"),top=l?l.scrollTop:0;
  fn();
  var l2=document.querySelector(".list");if(l2)l2.scrollTop=top;
  if(key){var n=document.querySelector('[data-key="'+key+'"]');if(n){n.focus();try{n.setSelectionRange(s,e)}catch(x){}}}
}
function refreshSide(){preserve(function(){var aside=document.querySelector(".side");if(aside)aside.parentNode.replaceChild(side(),aside)})}
function lastRound(){return S.rounds[S.rounds.length-1]}

function render(){preserve(draw)}
var wrapEl=null, slots=null, xp=false, pan=false, menuOpen=false;
var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
var PATHS={ask:'<circle cx="8" cy="8" r="6.25"/><path d="M6.3 6.2a1.8 1.8 0 1 1 2.6 1.6c-.6.3-.9.7-.9 1.3M8 11.4v.2"/>',
done:'<circle cx="8" cy="8" r="6.25"/><path d="M5.3 8.3l1.9 1.9 3.5-4"/>',
clock:'<circle cx="8" cy="8" r="6.25"/><path d="M8 4.8V8l2.2 1.4"/>',
chev:'<path d="M4 6l4 4 4-4"/>',check:'<path d="M3.5 8.5l3 3 6-7"/>',
ext:'<path d="M9 3h4v4M13 3L7.5 8.5M11 9.5V12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h2.5"/>',
expand:'<path d="M9.5 2.5h4v4M6.5 13.5h-4v-4M13.5 2.5L9 7M2.5 13.5L7 9"/>',
exit:'<path d="M13.5 2.5L9.5 6.5M9.5 2.5v4h4M2.5 13.5l4-4M6.5 13.5v-4h-4"/>',
comment:'<path d="M3 3.5h10a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H8l-3 2.5v-2.5H3a1 1 0 0 1-1-1v-6a1 1 0 0 1 1-1z"/>',
panel:'<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M10 3v10"/>',
area:'<rect x="2" y="3" width="12" height="10" rx="2" stroke-dasharray="2.5 2"/>'};
function icon(n){return '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+PATHS[n]+'</svg>'}
// A button with an icon and a text. The text is set with textContent, never as HTML.
function ibtn(cls,ic,text,attrs){var b=el("button",attrs||{});b.type="button";b.className=cls;if(ic)b.innerHTML=icon(ic);if(text)b.appendChild(el("span",{text:text}));return b}
function sget(k){try{return sessionStorage.getItem(k+ID)}catch(e){return null}}
function sset(k,v){try{sessionStorage.setItem(k+ID,v)}catch(e){}}
function isLatest(){return current.seq===lastRound().seq}
function pad(n){return n<10?"0"+n:String(n)}
function when(t){
  var d=new Date(t),n=new Date(),hm=pad(d.getHours())+":"+pad(d.getMinutes());
  function day(x){return new Date(x.getFullYear(),x.getMonth(),x.getDate()).getTime()}
  var diff=Math.round((day(n)-day(d))/86400000);
  return diff===0?"Today, "+hm:diff===1?"Yesterday, "+hm:d.getDate()+" "+MON[d.getMonth()]+", "+hm;
}
function roundName(r){return r.label&&r.label!=="Round "+r.seq?r.label:""}
function roundTitle(r){var n=roundName(r);return "Round "+r.seq+(n?" · "+n:"")+(r.variant&&r.variant!=="main"?" ("+r.variant+")":"")}

function draw(){
  document.getElementById("mode").textContent=S.mode==="emails"?"Only listed emails":"Anyone with the link";
  var you=document.getElementById("you");
  if(S.viewer){you.hidden=false;you.textContent=S.viewer.name+(S.viewer.kind==="guest"?" · guest":S.viewer.kind==="owner"?" · owner":"")}else you.hidden=true;
  document.getElementById("out").hidden=!(S.viewer&&S.viewer.signed_in);
  if(!S.rounds.length){app.replaceChildren(el("div",{class:"gate"},[el("h2",{text:"Nothing to look at yet"}),el("p",{text:"The owner has not shared a round. Come back soon."})]));frame=null;wrapEl=null;return}
  // The round object of the last answer: its link has the newest ticket. A round the person picked stays,
  // even when a newer one arrives.
  var same=current&&S.rounds.filter(function(r){return r.seq===current.seq})[0];
  current=same||lastRound();
  menuOpen=false;
  // Keep the frame while the round stays the same, so a new comment does not reload the page or lose the scroll.
  // Moving an iframe in the DOM reloads it, so then only the slots and the side panel change.
  var keep=frame&&frame._seq===current.seq&&frame.isConnected&&wrapEl&&wrapEl.isConnected;
  if(!keep){
    frame=el("iframe",{src:current.src,sandbox:"allow-scripts",title:"Round "+current.seq,referrerpolicy:"no-referrer"});
    frame._seq=current.seq;frameH=0;
    slots={ask:el("div",{class:"slot slot-ask"}),tb:el("div",{class:"slot slot-tb"}),late:el("div",{class:"slot"}),fab:el("div",{class:"slot"})};
    wrapEl=el("div",{class:"wrap"+(xp?" xp":"")+(xp&&pan?" pan":"")+(!xp&&folded()?" folded":"")},[el("section",{class:"main"},[slots.ask,slots.tb,slots.late,el("div",{class:"frame"},[frame])]),side(),slots.fab]);
    app.replaceChildren(wrapEl);
  }else{
    wrapEl.replaceChild(side(),wrapEl.querySelector(".side"));
    wrapEl.classList.toggle("folded",!xp&&folded());
  }
  fillSlots();
  applyHeight();
  sendBoxes();
  refreshTicket();
}
function fillSlots(){
  var a=askSection(),t=toolbar(),l=lateBar();
  slots.ask.replaceChildren.apply(slots.ask,a?[a]:[]);
  slots.tb.replaceChildren(t);
  slots.late.replaceChildren.apply(slots.late,l?[l]:[]);
  slots.fab.replaceChildren(fabBtn());
}

// --- the ask: one bar, and the full ask when the person opens it ---
function askOpen(){return sget("waggle-ask:")==="1"}
function askSection(){
  var last=isLatest(), a=last?(S.ask||current.ask):current.ask, d=last&&S.status==="decided"?S.decided:null;
  if(!a&&!d)return null;
  var open=askOpen(), opts=a&&a.options||[], rec=null;
  for(var i=0;i<opts.length;i++)if(opts[i].recommended){rec=opts[i];break}
  var recText=rec?rec.title:a&&a.recommendation||"";
  var chosen=d?(d.options||[]).join(", "):"";
  var bar=el("div",{class:"askbar"+(d?" done":"")});
  var ic=el("span",{});ic.innerHTML=icon(d?"done":"ask");ic.style.display="inline-flex";
  bar.appendChild(ic);
  bar.appendChild(el("span",{class:"q",title:a?a.need:"",text:d?"Decided: "+(chosen||"Answered"):firstLine(a.need)}));
  if(!d&&opts.length)bar.appendChild(el("span",{class:"pill",text:opts.length+(opts.length===1?" option":" options")}));
  if(!d&&recText)bar.appendChild(el("span",{class:"rec1",text:"I recommend "+recText}));
  var show=el("button",{class:"primary",type:"button","aria-expanded":String(open),text:open?"Hide":"Show",onclick:function(){sset("waggle-ask:",open?"0":"1");fillSlots()}});
  bar.appendChild(show);
  return el("div",{class:"askwrap"},open?[bar,askBlock(a,d)]:[bar]);
}
// The full ask of the round that is open. The last round shows the case's newest question; an earlier round keeps its own.
function askBlock(a,d){
  var past=!isLatest()||S.status==="decided", parts=[];
  if(d){
    var chosen=(d.options||[]).join(", ");
    parts.push(el("div",{class:"decided"},[el("div",{class:"k",text:"Decided"}),el("b",{text:chosen||"Answered"}),d.note?el("p",{text:d.note}):null,el("div",{class:"hint",text:ago(d.at)})]));
  }
  if(a){
    var opts=a.options||[], rec=null;
    for(var i=0;i<opts.length;i++)if(opts[i].recommended){rec=opts[i];break}
    if(rec||a.recommendation){
      var head=rec?rec.title:a.recommendation, sub=rec?(a.recommendation||rec.label):"";
      parts.push(el("div",{class:"rec"},[el("div",{class:"k",text:"Recommended"}),el("b",{text:head}),sub?el("p",{text:sub}):null]));
    }
    var cols=[el("div",{},[el("div",{class:"k",text:past?"Asked":"Need from you"}),el("p",{text:a.need})])];
    if(a.why)cols.push(el("div",{},[el("div",{class:"k",text:"Why I can’t decide"}),el("p",{text:a.why})]));
    parts.push(el("div",{class:"nw"},cols));
    if(opts.length)parts.push(el("div",{class:"opts"},opts.map(function(o){
      return el("div",{class:"opt"+(o.recommended?" rc":"")},[el("b",{text:o.title+(o.recommended?" · recommended":"")}),el("p",{text:o.label})])})));
  }
  return el("div",{class:"ask"+(past?" past":"")},parts);
}

// --- the rounds toolbar ---
function pick(r){current=r;anchor=null;tool="text";menuOpen=false;render();var b=document.getElementById("ebtn");if(b)b.focus()}
function goLatest(){pick(lastRound())}
function toolbar(){
  var n=S.rounds.length, chipKids=[el("span",{text:roundTitle(current)})];
  if(isLatest())chipKids.push(el("em",{class:"latest",text:"Latest"}));
  var left=[el("span",{class:"rchip"},chipKids)];
  if(n>1){
    var eb=ibtn("btn","clock","Earlier rounds ("+(n-1)+")",{id:"ebtn","aria-haspopup":"menu","aria-expanded":"false"});
    eb.insertAdjacentHTML("beforeend",icon("chev"));
    eb.addEventListener("click",function(){menuOpen?closeMenu(false):openMenu(false)});
    eb.addEventListener("keydown",function(ev){if(ev.key==="ArrowDown"&&!menuOpen){ev.preventDefault();openMenu(true)}});
    left.push(el("div",{class:"dd",id:"dd"},[eb]));
  }
  toolBtn=ibtn("btn","area","Comment on an area",{"aria-pressed":String(tool==="area"),title:"Drag a box over a part of the page. Esc to stop.",onclick:function(){setTool(tool==="area"?"text":"area")}});
  var tab=ibtn("btn","ext","Open in new tab",{onclick:openTab});
  var ex=ibtn("btn nox","expand","Expand",{id:"xbtn","aria-keyshortcuts":"F",title:"Open the page over the whole window. Key: F",onclick:function(){setXp(true)}});
  var exit=ibtn("btn xonly","exit","Exit",{id:"exitbtn",title:"Close the full view. Key: Esc",onclick:function(){setXp(false)}});
  exit.appendChild(el("kbd",{text:"Esc"}));
  var mark=el("span",{class:"xmark xonly"});mark.innerHTML=LOGO;
  return el("div",{class:"tb"},[mark,el("div",{class:"l"},left),el("div",{class:"r"},[toolBtn,tab,ex,exit])]);
}
function lateBar(){
  if(isLatest())return null;
  return el("div",{class:"late"},[el("span",{text:"You are viewing round "+current.seq+" of "+S.rounds.length+". Comments here go to round "+current.seq+"."}),el("button",{class:"btn",type:"button",text:"Go to latest",onclick:goLatest})]);
}
function menuItems(){return Array.prototype.slice.call(document.querySelectorAll("#dd .mi"))}
function openMenu(focusFirst){
  var dd=document.getElementById("dd");if(!dd||menuOpen)return;
  var last=lastRound().seq;
  var items=S.rounds.slice().reverse().map(function(r){
    var sel=r.seq===current.seq, nm=roundName(r)+(r.variant&&r.variant!=="main"?" ("+r.variant+")":"");
    var nameRow=el("span",{class:"nm"},[el("span",{text:nm||"Round "+r.seq})]);
    if(r.seq===last)nameRow.appendChild(el("em",{class:"latest",text:"Latest"}));
    var b=el("button",{class:"mi",type:"button",role:"menuitemradio","aria-checked":String(sel),tabindex:"-1",onclick:function(){pick(r)}},[el("span",{class:"n",text:String(r.seq)}),el("span",{class:"t"},[nameRow,el("small",{text:when(r.created_at)})])]);
    if(sel)b.insertAdjacentHTML("beforeend",icon("check"));
    return b;
  });
  var menu=el("div",{class:"menu",role:"menu","aria-label":"Rounds, newest first"},[el("div",{class:"mh",text:"Rounds, newest first"})].concat(items));
  menu.addEventListener("keydown",function(ev){
    var list=menuItems(),i=list.indexOf(document.activeElement);
    if(ev.key==="ArrowDown"){ev.preventDefault();list[(i+1)%list.length].focus()}
    else if(ev.key==="ArrowUp"){ev.preventDefault();list[(i-1+list.length)%list.length].focus()}
    else if(ev.key==="Home"){ev.preventDefault();list[0].focus()}
    else if(ev.key==="End"){ev.preventDefault();list[list.length-1].focus()}
    else if(ev.key==="Escape"){ev.preventDefault();ev.stopPropagation();closeMenu(true)}
    else if(ev.key==="Tab")closeMenu(false);
  });
  dd.appendChild(menu);menuOpen=true;
  document.getElementById("ebtn").setAttribute("aria-expanded","true");
  if(focusFirst){var sel=menuItems().filter(function(b){return b.getAttribute("aria-checked")==="true"})[0]||menuItems()[0];if(sel)sel.focus()}
}
function closeMenu(refocus){
  var dd=document.getElementById("dd");if(!dd||!menuOpen)return;
  var m=dd.querySelector(".menu");if(m)dd.removeChild(m);
  menuOpen=false;
  var b=document.getElementById("ebtn");if(b){b.setAttribute("aria-expanded","false");if(refocus)b.focus()}
}
document.addEventListener("pointerdown",function(ev){if(menuOpen&&!ev.target.closest("#dd"))closeMenu(false)});
// Open in new tab: a link with a fresh ticket. A ticket close to its end is replaced first.
function openTab(){
  var r=S.rounds.filter(function(x){return x.seq===current.seq})[0]||current;
  function go(url){var a=document.createElement("a");a.href=url;a.target="_blank";a.rel="noopener";document.body.appendChild(a);a.click();a.remove()}
  if(expOf(r.src)*1000-Date.now()>60000){go(r.src);return}
  api("/state").then(function(s){var n=s.rounds.filter(function(x){return x.seq===current.seq})[0];take(s);go((n||r).src)}).catch(function(){go(r.src)});
}

// --- Expand: the page over the whole window, comments in a slide-over ---
function setXp(on){
  if(!wrapEl)return;
  xp=on;if(!on)pan=false;
  closeMenu(false);
  wrapEl.classList.toggle("xp",on);wrapEl.classList.toggle("pan",on&&pan);wrapEl.classList.toggle("folded",!on&&folded());
  document.body.classList.toggle("lock",on);
  var top=document.querySelector(".top");if(top)top.inert=on;
  applyHeight();
  refreshSide();
  var f=document.getElementById(on?"exitbtn":"xbtn");if(f)f.focus();
}
function setPan(on){
  if(!wrapEl||!xp)return;
  pan=on;wrapEl.classList.toggle("pan",on);
  if(on){var t=wrapEl.querySelector('[data-key="compose"]');if(t)t.focus();else{var c=wrapEl.querySelector(".side .icon");if(c)c.focus()}}
  else{var f=wrapEl.querySelector(".fab");if(f)f.focus()}
}
function fabBtn(){
  var f=ibtn("fab","comment","Comments "+rootsOfRound().length,{type:"button",onclick:function(){setPan(true)}});
  return f;
}
// Escape closes the menu first, then the comments panel, then the full view.
function escape(){
  if(menuOpen){closeMenu(true);return true}
  if(xp&&pan){setPan(false);return true}
  if(xp){setXp(false);return true}
  return false;
}
window.addEventListener("keydown",function(ev){
  if(ev.defaultPrevented||ev.metaKey||ev.ctrlKey||ev.altKey)return;
  if(ev.key==="Escape"){if(escape())ev.preventDefault();return}
  var t=ev.target,tag=t&&t.tagName;
  if((ev.key==="f"||ev.key==="F")&&!xp&&wrapEl&&tag!=="INPUT"&&tag!=="TEXTAREA"&&tag!=="SELECT"&&!(t&&t.isContentEditable)){ev.preventDefault();setXp(true)}
});
// The comment panel folds to a thin rail. The choice stays for this case in this tab.
function folded(){return sget("waggle-fold:")==="1"}
function setFolded(on){sset("waggle-fold:",on?"1":"0");if(wrapEl)wrapEl.classList.toggle("folded",on&&!xp);refreshSide()}
function rootsOfRound(){return S.comments.filter(function(c){return c.round_seq===current.seq&&!c.parent_id})}
// On a phone the frame is as tall as its page, so the page scrolls as one and leaves no blank area.
var frameH=0;
function narrow(){return window.matchMedia("(max-width:800px)").matches}
function applyHeight(){if(!frame)return;frame.style.height=narrow()&&frameH&&!xp?frameH+"px":""}
window.addEventListener("resize",applyHeight);
document.getElementById("out").addEventListener("click",signOut);
// The frame has an opaque origin, so messages to it use "*". They carry only boxes and the tool.
function toFrame(m){if(frame&&frame.contentWindow)frame.contentWindow.postMessage(m,"*")}
function clearQuote(){toFrame({type:"waggle-clear-quote"})}
function setTool(t){tool=t;if(toolBtn)toolBtn.setAttribute("aria-pressed",String(t==="area"));toFrame({type:"waggle-tool",tool:t})}
function areaComments(){return S.comments.filter(function(c){return c.round_seq===current.seq&&c.box&&!c.parent_id})}
function sendBoxes(){
  var list=areaComments().map(function(c,i){return {n:i+1,x:c.box.x,y:c.box.y,w:c.box.w,h:c.box.h,vw:c.box.vw,near:c.box.near}});
  if(anchor&&anchor.box)list.push({x:anchor.box.x,y:anchor.box.y,w:anchor.box.w,h:anchor.box.h,vw:anchor.box.vw,near:anchor.box.near,pending:true});
  toFrame({type:"waggle-boxes",boxes:list});toFrame({type:"waggle-tool",tool:tool});
}
function areaChip(n,box,onclick){
  var near=box.near||"";
  return el("button",{class:"area",type:"button",title:"Show this area in the page",onclick:onclick},[n?el("b",{text:String(n)}):null,el("span",{text:near?(near.slice(0,6)==="image "?"Area on "+near:"Area near “"+near+"”"):"Area "+box.w+" × "+box.h})]);
}

// --- the live page: new comments and rounds, and the tickets of the frame ---
// A round link carries a ticket that ends. The page asks for a fresh link before the old one ends, and
// the frame comes back to the same place. A link that already ended gets the same one reload.
function expOf(src){var m=/\/t\/(\d+)\./.exec(src||"");return m?Number(m[1]):0}
function refreshTicket(){
  if(!frame||!frame.isConnected||!S)return;
  var r=S.rounds.filter(function(x){return x.seq===frame._seq})[0];if(!r)return;
  var have=expOf(frame.getAttribute("src"));
  if(have*1000-Date.now()>TICKET_LEFT_MS||expOf(r.src)<=have)return;
  swapFrame(r.src);
}
// Ask the frame where it is, then give it the new link. It reports its place again when it is ready.
function swapFrame(src){
  var f=frame;
  pendingScroll=null;toFrame({type:"waggle-scroll-get"});
  setTimeout(function(){if(frame===f&&f.isConnected)f.setAttribute("src",src)},250);
}
// A page that was paused (or hidden) while its link ran out comes back to a dead link. One look at the state
// gives a new one, and the frame reloads itself once.
var renewing=false;
function renewFrame(){
  if(renewing||!S||!frame||!frame.isConnected)return;
  var have=expOf(frame.getAttribute("src"));
  if(have*1000-Date.now()>TICKET_LEFT_MS)return;
  renewing=true;
  api("/state").then(function(s){
    var r=s.rounds.filter(function(x){return x.seq===frame._seq})[0];
    if(r&&expOf(r.src)>have)swapFrame(r.src);
  }).catch(function(){}).then(function(){renewing=false});
}
function active(){lastActive=Date.now();if(paused)renewFrame()}
["pointerdown","keydown","wheel","touchstart"].forEach(function(t){window.addEventListener(t,active,{passive:true})});
function poll(){
  if(!S||document.hidden||paused)return;
  if(Date.now()-lastActive>IDLE_MS){paused=true;refreshSide();return}
  api("/state").then(take).catch(function(e){if(e.status===410)gone(e.message)});
}
setInterval(poll,POLL_MS);
document.addEventListener("visibilitychange",function(){if(!document.hidden){poll();if(paused)renewFrame()}});

// --- the comment list: a thread is a comment with its replies ---
function kindLabel(c){return c.author_kind==="guest"?"guest · ":c.author_kind==="owner"?"owner · ":c.author_kind==="agent"?"agent · ":""}
function firstLine(t){return String(t).split("\n")[0]}
function act(path){api(path,{method:"POST"}).then(load).catch(function(e){alert(e.message)})}

function thread(c,n,replies){
  var done=!!c.resolved_at;
  if(done&&!expanded[c.id]){
    var f=el("button",{class:"fold",type:"button",title:"Show the thread",onclick:function(){expanded[c.id]=true;refreshSide()}},[el("span",{class:"ok",text:"Resolved"}),el("span",{class:"first",text:c.author_name+": "+firstLine(c.body)}),replies.length?el("small",{text:String(replies.length+1)}):null]);
    return el("div",{class:"c done"},[f]);
  }
  var acts=[];
  if(S.viewer&&(!S.comments_closed||S.viewer.kind==="owner")&&replying!==c.id)acts.push(el("button",{class:"lnk",type:"button",text:"Reply",onclick:function(){replying=c.id;refreshSide();var t=document.querySelector('[data-key="reply:'+c.id+'"]');if(t)t.focus()}}));
  if(c.can_resolve)acts.push(el("button",{class:"lnk",type:"button",text:done?"Reopen":"Resolve",onclick:function(){act("/comments/"+c.id+"/"+(done?"reopen":"resolve"))}}));
  if(done)acts.push(el("button",{class:"lnk",type:"button",text:"Hide",onclick:function(){delete expanded[c.id];refreshSide()}}));
  var kids=replies.map(function(r){
    return el("div",{class:"reply"},[el("div",{class:"who"},[document.createTextNode(r.author_name),el("small",{text:kindLabel(r)+ago(r.created_at)})]),el("p",{text:r.body})]);
  });
  var parts=[el("div",{class:"who"},[document.createTextNode(c.author_name),el("small",{text:kindLabel(c)+ago(c.created_at)})]),c.box?areaChip(n,c.box,function(){toFrame({type:"waggle-focus",n:n})}):null,c.quote?el("blockquote",{text:c.quote}):null,el("p",{text:c.body})];
  if(kids.length)parts.push(el("div",{class:"replies"},kids));
  if(replying===c.id)parts.push(replyBox(c));
  if(acts.length)parts.push(el("div",{class:"acts"},acts));
  return el("div",{class:"c"},parts);
}

function replyBox(c){
  var t=el("textarea",{rows:"2",placeholder:"Reply",maxlength:"4000","data-key":"reply:"+c.id}), err=el("div",{class:"err"});
  t.value=replyDraft[c.id]||"";
  var send=el("button",{class:"primary",type:"button",text:"Reply"});
  function fit(){send.disabled=!t.value.trim()}
  t.addEventListener("input",function(){replyDraft[c.id]=t.value;fit()});
  t.addEventListener("keydown",function(ev){ev.stopPropagation();if(ev.key==="Enter"&&(ev.metaKey||ev.ctrlKey)){ev.preventDefault();go()}if(ev.key==="Escape"){replying=null;refreshSide()}});
  function go(){if(!t.value.trim())return;send.disabled=true;
    api("/comments",{method:"POST",body:JSON.stringify({parent_id:c.id,body:t.value})}).then(function(){delete replyDraft[c.id];replying=null;load()}).catch(function(e){err.textContent=e.message;send.disabled=false})}
  send.addEventListener("click",go);
  var cancel=el("button",{class:"lnk",type:"button",text:"Cancel",onclick:function(){replying=null;refreshSide()}});
  fit();
  return el("div",{class:"rbox"},[t,err,el("div",{class:"row"},[cancel,send])]);
}

function side(){
  var inRound=S.comments.filter(function(c){return c.round_seq===current.seq}), roots=inRound.filter(function(c){return !c.parent_id}), areas=areaComments(), kids={};
  inRound.forEach(function(c){if(c.parent_id)(kids[c.parent_id]=kids[c.parent_id]||[]).push(c)});
  var list=el("div",{class:"list"},roots.length?roots.map(function(c){return thread(c,areas.indexOf(c)+1,kids[c.id]||[])}):[el("div",{class:"empty",text:"No comments on this round yet. Select text, or drag a box with Comment on an area, to point at a part."})]);
  if(!xp&&folded()){
    var rb=ibtn("icon","comment","",{"aria-label":"Show the comments ("+roots.length+")",title:"Show the comments"});
    rb.addEventListener("click",function(){setFolded(false)});
    return el("aside",{class:"side rail"},[rb,el("b",{text:String(roots.length)})]);
  }
  var head=[el("div",{class:"label",text:"Comments · round "+current.seq})];
  var ctl=xp?ibtn("icon","",""):ibtn("icon","panel","");
  if(xp){ctl.innerHTML=X;ctl.setAttribute("aria-label","Hide the comments");ctl.title="Hide the comments";ctl.addEventListener("click",function(){setPan(false)})}
  else{ctl.setAttribute("aria-label","Fold the comments");ctl.title="Fold the comments";ctl.addEventListener("click",function(){setFolded(true)})}
  // Only the owner, signed in, closes or opens the comments.
  if(S.viewer&&S.viewer.kind==="owner"&&S.viewer.signed_in){
    var cl=el("button",{class:"tool",type:"button",text:S.comments_closed?"Open comments":"Close comments",onclick:function(){api("",{method:"PATCH",body:JSON.stringify({comments_closed:!S.comments_closed})}).then(load).catch(function(e){alert(e.message)})}});
    head.push(el("div",{style:"padding-top:10px"},[cl]));
  }
  head.push(el("span",{style:"flex:1"}));head.push(ctl);
  var kidsOfSide=[el("div",{class:"sidehead"},head),composer()];
  if(paused)kidsOfSide.push(el("div",{class:"note",text:"Paused. Reload for new comments."}));
  kidsOfSide.push(list);
  return el("aside",{class:"side"},kidsOfSide);
}

function composer(){
  var box=el("div",{class:"compose"});
  if(S.comments_closed&&!(S.viewer&&S.viewer.kind==="owner")){box.appendChild(el("div",{class:"hint",text:"Comments are closed."}));return box}
  if(!S.viewer){
    var name=el("input",{type:"text",placeholder:"Your name",maxlength:"60",autocomplete:"name"}), err=el("div",{class:"err"});
    var go=el("button",{class:"primary",text:"Join to comment"});
    var f=el("form",{},[el("div",{class:"hint",text:"Tell the team who you are. You join as a guest."}),name,err,el("div",{class:"row"},[el("span"),go])]);
    f.style.cssText="display:flex;flex-direction:column;gap:8px";
    f.addEventListener("submit",function(ev){ev.preventDefault();if(!name.value.trim())return;go.disabled=true;api("/guest",{method:"POST",body:JSON.stringify({name:name.value})}).then(function(){load()}).catch(function(e){err.textContent=e.message;go.disabled=false})});
    box.appendChild(f);return box;
  }
  var label=!anchor?"":anchor.box?(anchor.box.near?(anchor.box.near.slice(0,6)==="image "?"Area on "+anchor.box.near:"Area near “"+anchor.box.near+"”"):"Area "+anchor.box.w+" × "+anchor.box.h):"“"+anchor.quote+"”";
  var q=el("div",{class:"quote"+(anchor?" on":"")},[el("span",{text:label}),el("button",{type:"button","aria-label":anchor&&anchor.box?"Remove area":"Remove quote",onclick:function(){var had=anchor&&anchor.box;anchor=null;q.classList.remove("on");if(had)sendBoxes();else clearQuote()}})]);
  q.lastChild.innerHTML=X;
  if(anchor&&!anchor.box)q.classList.add("q-text");
  var t=el("textarea",{rows:"1",placeholder:anchor?"Comment on this part":"Add a comment",maxlength:"4000","data-key":"compose"});
  function fit(){t.style.height="auto";t.style.height=Math.min(t.scrollHeight,104)+"px";send.disabled=!t.value.trim()}
  t.addEventListener("input",function(){draft=t.value;fit()});
  t.addEventListener("keydown",function(ev){ev.stopPropagation();if(ev.key==="Enter"&&(ev.metaKey||ev.ctrlKey)){ev.preventDefault();post()}if(ev.key==="Escape"&&escape())ev.preventDefault()});
  var err=el("div",{class:"err"});
  var send=el("button",{class:"primary",text:"Comment",disabled:"",onclick:post});
  function post(){if(!t.value.trim())return;send.disabled=true;var b={round_seq:current.seq,body:t.value};if(anchor&&anchor.box)b.box=anchor.box;else if(anchor){b.quote=anchor.quote;b.prefix=anchor.prefix;b.suffix=anchor.suffix}
    api("/comments",{method:"POST",body:JSON.stringify(b)}).then(function(){anchor=null;draft="";clearQuote();load()}).catch(function(e){err.textContent=e.message;send.disabled=false})}
  box.append(q,t,err,el("div",{class:"row"},[el("span",{class:"hint",text:"⌘ Enter to send"}),send]));
  // A typed draft survives a new selection, a new area and a refresh of the comments.
  if(draft){t.value=draft;fit()}
  box._focus=t;return box;
}

window.addEventListener("message",function(ev){
  if(!frame||ev.source!==frame.contentWindow)return;
  var d=ev.data;if(!d||typeof d.type!=="string")return;
  if(d.type==="waggle-ready"){sendBoxes();if(pendingScroll&&pendingScroll.got)toFrame({type:"waggle-scroll-set",x:pendingScroll.x,y:pendingScroll.y});return}
  if(d.type==="waggle-scroll"){if(typeof d.x==="number"&&typeof d.y==="number")pendingScroll={got:true,x:d.x,y:d.y};return}
  if(d.type==="waggle-size"){
    if(typeof d.h==="number"&&isFinite(d.h)){frameH=Math.min(Math.max(Math.round(d.h),0),30000);applyHeight()}
    // The page has its height now: put the scroll back once, then forget it.
    if(pendingScroll&&pendingScroll.got){toFrame({type:"waggle-scroll-set",x:pendingScroll.x,y:pendingScroll.y});pendingScroll=null}
    return}
  if(d.type==="waggle-tool"){setTool(d.tool==="area"?"area":"text");return}
  active();
  if(d.type==="waggle-activity")return;
  if(d.type==="waggle-area"&&d.anchor){
    var a=d.anchor,ok=["x","y","w","h","vw"].every(function(k){return typeof a[k]==="number"&&isFinite(a[k])&&a[k]>=0});
    if(!ok)return;
    anchor={box:{x:Math.round(a.x),y:Math.round(a.y),w:Math.round(a.w),h:Math.round(a.h),vw:Math.round(a.vw)||1,near:String(a.near||"").slice(0,200)}};
    setTool("text");sendBoxes();
  }else if(d.type==="waggle-selection"&&d.anchor&&typeof d.anchor.quote==="string"){
    var had=anchor&&anchor.box;
    anchor={quote:String(d.anchor.quote).slice(0,1000),prefix:String(d.anchor.prefix||"").slice(0,64),suffix:String(d.anchor.suffix||"").slice(0,64)};
    if(had)sendBoxes();
  }else return;
  if(xp&&!pan)setPan(true);else if(!xp&&folded())setFolded(false);
  var aside=document.querySelector(".side");if(aside&&aside.children[1]){var c=composer();aside.replaceChild(c,aside.children[1]);if(c._focus){c._focus.focus();var n=c._focus.value.length;c._focus.setSelectionRange(n,n)}}
});
load();
})();`;
