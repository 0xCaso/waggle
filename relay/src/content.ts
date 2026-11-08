import { checkTicket } from "./auth";
import { scaleBox } from "./box";
import type { Env } from "./env";
import { roundStore } from "./store";

// The content origin serves the files of a round, and nothing else. They are untrusted:
// the CSP sandboxes them (no same-origin, no network, no forms) even when opened directly.
export async function serveContent(env: Env, request: Request, url: URL): Promise<Response> {
  if (request.method !== "GET") return new Response("Not found", { status: 404 });
  // /t/<ticket>/<case>/<commit>/<path...>
  const m = url.pathname.match(/^\/t\/([^/]+)\/([a-z0-9]+)\/([0-9a-f]{40})\/(.+)$/);
  if (!m) return new Response("Not found", { status: 404 });
  const [, t, id, commitId, rawPath] = m;
  if (!(await checkTicket(env, t, id, commitId))) return new Response("This link has expired. Reload the page.", { status: 403 });
  const path = decodeURIComponent(rawPath);
  const file = await roundStore(env).readFile(id, commitId, path);
  if (!file) return new Response("Not found", { status: 404 });

  const headers = new Headers({
    "content-security-policy": [
      "sandbox allow-scripts",
      "default-src 'self' 'unsafe-inline' data: blob:",
      "connect-src 'none'",
      "form-action 'none'",
      `frame-ancestors ${env.APP_ORIGIN}`,
    ].join("; "),
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "cache-control": "private, max-age=300",
  });

  if (file.type.startsWith("text/html")) {
    headers.set("content-type", "text/html; charset=utf-8");
    return new Response(new TextDecoder().decode(file.body) + selectionScript(env), { headers });
  }
  if (file.type.startsWith("text/markdown")) {
    headers.set("content-type", "text/html; charset=utf-8");
    return new Response(markdownPage(new TextDecoder().decode(file.body)) + selectionScript(env), { headers });
  }
  // An image or a diagram opened as a round (the state asks with ?view=1) sits in a page with the area script.
  // The same path without the query is the raw file, which the page itself and relative links use.
  if (url.searchParams.get("view") === "1" && file.type.startsWith("image/")) {
    const name = path.split("/").pop() ?? path;
    headers.set("content-type", "text/html; charset=utf-8");
    // The page that links the round may name the other images of a screenshots round. Plain file names only.
    const gallery = (url.searchParams.get("g") ?? "").split(",").filter((g) => /^[A-Za-z0-9._-]{1,100}$/.test(g)).slice(0, 12);
    return new Response(imagePage(name, file.type, file.body, env, gallery), { headers });
  }
  headers.set("content-type", file.type);
  return new Response(file.body, { headers });
}

function htmlEscape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// The wrapper for one image round. A raster image is an <img> that points at the raw file. An SVG goes inline,
// so its text can be selected; it is as untrusted as an HTML round and runs under the same sandbox.
function imagePage(name: string, type: string, bytes: ArrayBuffer, env: Env, gallery: string[] = []): string {
  const svg = type.startsWith("image/svg");
  // A screenshots round has several images. They stack in the page; each has its own name for the area comment.
  if (!svg && gallery.length > 1) {
    const imgs = gallery.map((g) => `<img data-wg="${htmlEscape(g)}" src="${encodeURIComponent(g)}" alt="${htmlEscape(g)}">`).join("");
    const head = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${htmlEscape(name)}</title><style>html,body{margin:0;background:#fff}body>img{display:block;max-width:100%;height:auto;margin:0 0 12px}</style></head><body>`;
    return `${head}${imgs}${selectionScript(env, gallery.map((g) => ({ name: g, kind: "img" as const })))}</body></html>`;
  }
  const head = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${htmlEscape(name)}</title><style>html,body{margin:0;background:#fff}body>img,body>svg{display:block;max-width:100%;height:auto}</style></head><body>`;
  const inner = svg
    ? new TextDecoder().decode(bytes).replace(/<\?xml[\s\S]*?\?>/g, "").replace(/<!DOCTYPE[\s\S]*?>/gi, "").trim()
    : `<img data-wg="${htmlEscape(name)}" src="${encodeURIComponent(name)}" alt="${htmlEscape(name)}">`;
  return `${head}${inner}${selectionScript(env, [{ name, kind: svg ? "svg" : "img" }])}</body></html>`;
}

// Lets the reader point at a part of the page: select text, or drag a box over an area.
// The frame has an opaque origin, so the page checks event.source, not event.origin, and the
// frame checks that a message comes from its parent. Boxes are drawn with textContent only.
function selectionScript(env: Env, images?: { name: string; kind: "img" | "svg" }[]): string {
  const target = JSON.stringify(env.APP_ORIGIN);
  return `<script>(function(){
  var T=${target}, IMG=${JSON.stringify(images ?? null).replace(/</g, "\\u003c")}, tool="text", layer=null, cover=null, draft=null, start=null, marks={}, lastBoxes=[], quoteMark=null;
  ${scaleBox.toString()}
  var calm=window.matchMedia&&matchMedia("(prefers-reduced-motion: reduce)").matches;
  function send(m){parent.postMessage(m,T)}
  // A quote starts and ends on whole words: a half word makes the quote hard to find in the source.
  function snap(sel){
    var r=sel.getRangeAt(0), a=r.startContainer, b=r.endContainer;
    if(a.nodeType===3){var i=r.startOffset,v=a.nodeValue;while(i>0&&/\\S/.test(v.charAt(i-1))) i--;r.setStart(a,i)}
    if(b.nodeType===3){var j=r.endOffset,u=b.nodeValue;while(j<u.length&&/\\S/.test(u.charAt(j))) j++;r.setEnd(b,j)}
    sel.removeAllRanges();sel.addRange(r);
    return r;
  }
  function clearQuote(){if(window.CSS&&CSS.highlights) CSS.highlights.delete("waggle-quote");quoteMark=null}
  // The selection turns grey when the reader types in the page's composer, so keep it lit here.
  function markQuote(r){
    if(!(window.CSS&&CSS.highlights&&window.Highlight)) return;
    if(!quoteMark){quoteMark=document.createElement("style");quoteMark.textContent="::highlight(waggle-quote){background:rgba(242,176,30,.5);color:inherit}";(document.head||document.documentElement).appendChild(quoteMark)}
    CSS.highlights.set("waggle-quote",new Highlight(r.cloneRange()));
    // The native selection paints over the highlight, and goes grey when focus leaves. Drop it.
    var sel=window.getSelection(); if(sel) sel.removeAllRanges();
  }
  function around(sel){
    var quote=sel.toString().trim();
    if(!quote) return null;
    var all=document.body.innerText||document.body.textContent||"", at=all.indexOf(quote);
    return {quote:quote.slice(0,1000),
      prefix: at>0? all.slice(Math.max(0,at-64),at):"",
      suffix: at>=0? all.slice(at+quote.length, at+quote.length+64):""};
  }
  document.addEventListener("mouseup",function(){
    if(tool!=="text") return;
    var s=window.getSelection(); if(!s||s.rangeCount===0) return;
    if(!s.toString().trim()) return;
    var r=snap(s), a=around(s); if(a){markQuote(r);send({type:"waggle-selection",anchor:a})}
  });

  function docSize(){var d=document.documentElement,b=document.body;return {w:Math.max(d.scrollWidth,b?b.scrollWidth:0),h:Math.max(d.scrollHeight,b?b.scrollHeight:0)}}
  function ensureLayer(){
    if(layer&&layer.isConnected) return;
    layer=document.createElement("div");
    layer.style.cssText="position:absolute;left:0;top:0;width:0;height:0;overflow:visible;pointer-events:none;z-index:2147483646;margin:0;padding:0;border:0";
    document.body.appendChild(layer);
  }
  function rect(b,state){
    var r=document.createElement("div");
    r.style.cssText="position:absolute;box-sizing:border-box;margin:0;padding:0;border-radius:6px;border:2px solid #F2B01E;background:rgba(242,176,30,.12);transition:box-shadow .2s ease-out";
    if(state==="pending") r.style.borderStyle="dashed";
    r.style.left=b.x+"px";r.style.top=b.y+"px";r.style.width=b.w+"px";r.style.height=b.h+"px";
    if(b.n){var t=document.createElement("span");t.textContent=String(b.n);
      t.style.cssText="position:absolute;left:-10px;top:-10px;min-width:20px;height:20px;padding:0 5px;box-sizing:border-box;border-radius:10px;background:#16181A;color:#fff;font:600 11px/20px -apple-system,system-ui,sans-serif;text-align:center";
      r.appendChild(t)}
    return r;
  }
  // An image round keeps a box in image pixels (vw = the image width), and "image <name>" in near names the image.
  // The image may be shown smaller than it is. A screenshots round stacks several images.
  function imgItem(name){if(!IMG)return null;for(var i=0;i<IMG.length;i++)if(IMG[i].name===name)return IMG[i];return IMG[0]}
  function imgEl(it){
    if(!it) return null;
    if(it.kind==="svg") return document.querySelector("body > svg");
    var all=document.images; for(var i=0;i<all.length;i++) if(all[i].getAttribute("data-wg")===it.name) return all[i];
    return null;
  }
  function geomOf(it){
    var e=imgEl(it); if(!e) return null;
    var r=e.getBoundingClientRect(), nw=it.kind==="svg"?((e.viewBox&&e.viewBox.baseVal&&e.viewBox.baseVal.width)||(e.width&&e.width.baseVal&&e.width.baseVal.value)||r.width):e.naturalWidth;
    if(!nw||!r.width) return null;
    return {k:r.width/nw,ox:r.left+scrollX,oy:r.top+scrollY,nw:nw,it:it};
  }
  // The image that holds a point of the page (the first one when none does).
  function itemAt(x,y){
    for(var i=0;i<IMG.length;i++){var e=imgEl(IMG[i]);if(!e)continue;var r=e.getBoundingClientRect();
      if(x>=r.left+scrollX&&x<=r.right+scrollX&&y>=r.top+scrollY&&y<=r.bottom+scrollY)return IMG[i]}
    return IMG[0];
  }
  function nameOfNear(near){return typeof near==="string"&&near.slice(0,6)==="image "?near.slice(6):""}
  function showBoxes(list){
    lastBoxes=list||[];
    ensureLayer();layer.replaceChildren();marks={};
    var width=document.documentElement.clientWidth;
    lastBoxes.forEach(function(b){
      if(!b||![b.x,b.y,b.w,b.h].every(function(v){return typeof v==="number"&&isFinite(v)})) return;
      var g=IMG?geomOf(imgItem(nameOfNear(b.near))):null;
      var s=IMG?(g?{x:b.x*g.k+g.ox,y:b.y*g.k+g.oy,w:b.w*g.k,h:b.h*g.k}:null):scaleBox(b,width);
      if(!s) return;
      var r=rect({x:s.x,y:s.y,w:s.w,h:s.h,n:b.n},b.pending?"pending":"saved");layer.appendChild(r);if(b.n) marks[b.n]=r;
    });
  }
  function focusBox(n){
    var r=marks[n]; if(!r) return;
    r.scrollIntoView({block:"center",behavior:calm?"auto":"smooth"});
    r.style.boxShadow="0 0 0 6px rgba(242,176,30,.35)";
    setTimeout(function(){r.style.boxShadow="none"},1200);
  }

  // The words that sit inside the box, so the agent can find the area again in the source.
  function textIn(b){
    var out="", prev=null, w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT), node, r=document.createRange();
    while((node=w.nextNode())&&out.length<400){
      if(layer&&layer.contains(node)) continue;
      var v=node.nodeValue.replace(/\\s+/g," "); if(!v.trim()) continue;
      r.selectNodeContents(node);
      var rs=r.getClientRects();
      for(var i=0;i<rs.length;i++){var q=rs[i],x=q.left+scrollX,y=q.top+scrollY;
        if(x<b.x+b.w&&x+q.width>b.x&&y<b.y+b.h&&y+q.height>b.y){
          var blk=blockOf(node);
          // Text nodes in one block join as they are written. A new block gets a space.
          out=blk===prev?out+v:out.replace(/\\s+$/,"")+" "+v.trim();
          prev=blk;break}}
    }
    return out.replace(/\\s+/g," ").trim().slice(0,200);
  }
  function blockOf(node){
    var e=node.parentElement;
    while(e&&e!==document.body&&/^inline/.test(getComputedStyle(e).display)&&getComputedStyle(e).display!=="inline-block") e=e.parentElement;
    return e;
  }
  function setTool(t){
    tool=t==="area"?"area":"text";
    if(tool==="text"){if(cover){cover.remove();cover=null}if(draft){draft.remove();draft=null}return}
    if(cover) return;
    cover=document.createElement("div");
    cover.style.cssText="position:fixed;inset:0;z-index:2147483647;cursor:crosshair;touch-action:none;background:rgba(22,24,26,.04);margin:0;padding:0;border:0";
    cover.addEventListener("pointerdown",function(ev){
      ev.preventDefault();cover.setPointerCapture(ev.pointerId);
      start={x:ev.clientX+scrollX,y:ev.clientY+scrollY};
      ensureLayer();draft=rect({x:start.x,y:start.y,w:0,h:0},"pending");layer.appendChild(draft);
    });
    cover.addEventListener("pointermove",function(ev){
      if(!start||!draft) return;
      var x=ev.clientX+scrollX,y=ev.clientY+scrollY;
      draft.style.left=Math.min(x,start.x)+"px";draft.style.top=Math.min(y,start.y)+"px";
      draft.style.width=Math.abs(x-start.x)+"px";draft.style.height=Math.abs(y-start.y)+"px";
    });
    cover.addEventListener("pointerup",function(ev){
      if(!start) return;
      var x=ev.clientX+scrollX,y=ev.clientY+scrollY;
      var b={x:Math.min(x,start.x),y:Math.min(y,start.y),w:Math.abs(x-start.x),h:Math.abs(y-start.y)};
      start=null;
      if(b.w<6||b.h<6){if(draft){draft.remove();draft=null}return}
      var g=IMG?geomOf(itemAt(b.x,b.y)):null;
      if(IMG&&g){
        // Image pixels, relative to the image. The box must touch the image; the part outside it is cut.
        var ix=Math.max(0,(b.x-g.ox)/g.k), iy=Math.max(0,(b.y-g.oy)/g.k);
        b={x:Math.round(ix),y:Math.round(iy),w:Math.max(4,Math.round(b.w/g.k)),h:Math.max(4,Math.round(b.h/g.k)),vw:Math.round(g.nw)||1,near:"image "+g.it.name};
      }else{b.vw=document.documentElement.clientWidth;b.near=textIn(b)}
      setTool("text");
      send({type:"waggle-area",anchor:b});
    });
    document.body.appendChild(cover);
  }
  document.addEventListener("keydown",function(ev){if(ev.key==="Escape"&&tool==="area"){setTool("text");send({type:"waggle-tool",tool:"text"})}});

  // Tell the page the reader is here, so it can renew a round link that ran out while it was paused.
  var lastActive=0;
  function activity(){var n=Date.now();if(n-lastActive>5000){lastActive=n;send({type:"waggle-activity"})}}
  document.addEventListener("pointerdown",activity,true);
  document.addEventListener("keydown",activity,true);
  window.addEventListener("message",function(ev){
    if(ev.source!==parent) return;
    var d=ev.data; if(!d||typeof d.type!=="string") return;
    if(d.type==="waggle-tool") setTool(d.tool);
    else if(d.type==="waggle-boxes") showBoxes(d.boxes);
    else if(d.type==="waggle-focus") focusBox(d.n);
    else if(d.type==="waggle-clear-quote") clearQuote();
    else if(d.type==="waggle-scroll-get") send({type:"waggle-scroll",x:scrollX,y:scrollY});
    else if(d.type==="waggle-scroll-set"&&typeof d.y==="number"&&typeof d.x==="number") scrollTo(d.x,d.y);
  });
  // The reader's frame can be any width. Outlines follow it, and the page learns how tall this page is.
  var lastH=0;
  function reportHeight(){
    var b=document.body; if(!b) return;
    var h=Math.ceil(b.getBoundingClientRect().bottom+scrollY+(parseFloat(getComputedStyle(b).marginBottom)||0));
    if(h!==lastH){lastH=h;send({type:"waggle-size",h:h})}
  }
  window.addEventListener("resize",function(){showBoxes(lastBoxes);reportHeight();setTimeout(reportHeight,150)});
  if(window.ResizeObserver){var ro=new ResizeObserver(reportHeight);ro.observe(document.documentElement);ro.observe(document.body)}
  window.addEventListener("load",function(){reportHeight();if(IMG)showBoxes(lastBoxes)});
  if(IMG) for(var ii=0;ii<IMG.length;ii++){var im=imgEl(IMG[ii]); if(im&&im.addEventListener) im.addEventListener("load",function(){showBoxes(lastBoxes);reportHeight()})}
  send({type:"waggle-ready",size:docSize()});
  reportHeight();
})();</script>`;
}

function markdownPage(md: string): string {
  const esc = md.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const html = esc
    .split(/\n{2,}/)
    .map((block) => {
      const h = block.match(/^(#{1,3}) (.*)$/);
      if (h) return `<h${h[1].length}>${h[2]}</h${h[1].length}>`;
      if (/^[-*] /m.test(block)) return `<ul>${block.split("\n").map((l) => `<li>${l.replace(/^[-*] /, "")}</li>`).join("")}</ul>`;
      return `<p>${block.replace(/\n/g, "<br>")}</p>`;
    })
    .join("\n");
  return `<!doctype html><meta charset="utf-8"><style>
body{font:15px/1.55 -apple-system,"Inter Tight",system-ui,sans-serif;color:#16181A;background:#fff;max-width:720px;margin:32px auto;padding:0 20px}
h1{font-size:24px;letter-spacing:-.02em}h2{font-size:18px}h3{font-size:15px}p,li{color:#4A4C50}
</style>${html}`;
}
