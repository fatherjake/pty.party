/* pty.party marketing canvas — a scripted, looping demo of the real app.
   Tiles live in "world" coordinates on a 3400×1900 plane; a camera pans and
   zooms over them as the story plays out. Mirrors Sources/ptyparty visuals. */

const SVGNS = "http://www.w3.org/2000/svg";
const viewport = document.getElementById("viewport");
const world = document.getElementById("world");
const grid = document.getElementById("grid");
const wires = document.getElementById("wires");
const edgeGlow = document.getElementById("edgeGlow");
const captionEl = document.getElementById("caption");
const progressEl = document.getElementById("progress");
const replayBtn = document.getElementById("replay");

/* ---- World layout: top-left x/y and size, in world px ------------------ */
const LAYOUT = {
  t1:      { x: 240,  y: 300, w: 560, h: 364 },
  log:     { x: 880,  y: 300, w: 320 },           // height is natural
  cat:     { x: 300,  y: 740, w: 250, h: 250 },
  t2:      { x: 610,  y: 720, w: 620, h: 404 },
  t3:      { x: 1400, y: 360, w: 560, h: 248 },
  browser: { x: 1430, y: 680, w: 520, h: 384 },
  t4:      { x: 3060, y: 430, w: 560, h: 388 },
};

const tiles = {};          // id -> { el, ...parts, rect() }
let runToken = 0;          // bumped on replay to cancel an in-flight run
let camera = { x: 0, y: 0, s: 1 };
let lastFocus = ["t1"];

/* ---- Tiny async helpers ------------------------------------------------ */
const sleep = (ms) => {
  const mine = runToken;
  return new Promise((res, rej) =>
    setTimeout(() => (mine === runToken ? res() : rej("cancel")), ms)
  );
};
const chars = (s) => Array.from(s); // code-point safe (emoji)

/* ---- Camera ------------------------------------------------------------ */
function rectOf(id) {
  const t = tiles[id];
  const L = LAYOUT[id];
  const w = t ? t.el.offsetWidth : L.w;
  const h = t ? t.el.offsetHeight : (L.h || 200);
  return { x: L.x, y: L.y, w, h };
}

function applyCamera(animate = true) {
  world.classList.toggle("no-anim", !animate);
  grid.classList.toggle("no-anim", !animate);
  world.style.transform = `translate(${camera.x}px, ${camera.y}px) scale(${camera.s})`;
  // Drive the viewport-filling dot grid from the camera so it pans and zooms
  // with the world but always covers the whole screen (no blank edges).
  const cell = 40 * camera.s;
  grid.style.backgroundSize = `${cell}px ${cell}px`;
  grid.style.backgroundPosition = `${camera.x}px ${camera.y}px`;
}

function focus(ids, { animate = true, maxScale = 1.05 } = {}) {
  lastFocus = ids;
  const rs = ids.map(rectOf);
  const minX = Math.min(...rs.map((r) => r.x));
  const minY = Math.min(...rs.map((r) => r.y));
  const maxX = Math.max(...rs.map((r) => r.x + r.w));
  const maxY = Math.max(...rs.map((r) => r.y + r.h));
  const bw = maxX - minX, bh = maxY - minY;
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;

  const vw = window.innerWidth, vh = window.innerHeight;
  const usableTop = 84, usableBottom = vh - 168;          // leave room for caption
  const usableH = Math.max(220, usableBottom - usableTop);
  const usableW = vw - 220;
  const s = Math.min(usableW / bw, usableH / bh, maxScale);
  const targetCx = vw / 2;
  const targetCy = usableTop + usableH / 2;

  camera = { x: targetCx - s * cx, y: targetCy - s * cy, s };
  applyCamera(animate);
}

/* ---- Connection wires (world-space SVG) -------------------------------- */
function anchor(rect, toward) {
  const inset = 9;
  const pts = [
    { x: rect.x + rect.w / 2, y: rect.y + inset },
    { x: rect.x + rect.w / 2, y: rect.y + rect.h - inset },
    { x: rect.x + inset,      y: rect.y + rect.h / 2 },
    { x: rect.x + rect.w - inset, y: rect.y + rect.h / 2 },
  ];
  return pts.reduce((best, p) =>
    Math.hypot(p.x - toward.x, p.y - toward.y) <
    Math.hypot(best.x - toward.x, best.y - toward.y) ? p : best
  );
}

async function drawWire(aId, bId, { dashed = false } = {}) {
  const a = rectOf(aId), b = rectOf(bId);
  const ca = { x: a.x + a.w / 2, y: a.y + a.h / 2 };
  const cb = { x: b.x + b.w / 2, y: b.y + b.h / 2 };
  const pa = anchor(a, cb), pb = anchor(b, ca);

  const path = document.createElementNS(SVGNS, "path");
  path.setAttribute("d", `M ${pa.x} ${pa.y} L ${pb.x} ${pb.y}`);
  if (dashed) path.style.strokeDasharray = "6 4";
  wires.appendChild(path);

  if (!dashed) {
    const len = path.getTotalLength();
    path.style.strokeDasharray = len;
    path.style.strokeDashoffset = len;
    path.getBoundingClientRect(); // reflow
    path.style.transition = "stroke-dashoffset 0.55s ease";
    path.style.strokeDashoffset = "0";
  }
  for (const p of [pa, pb]) {
    const dot = document.createElementNS(SVGNS, "circle");
    dot.setAttribute("cx", p.x); dot.setAttribute("cy", p.y);
    dot.setAttribute("r", 5); dot.setAttribute("class", "endpoint");
    wires.appendChild(dot);
  }
  await sleep(420);
}

/* ---- Tile factories ---------------------------------------------------- */
function place(el, id) {
  const L = LAYOUT[id];
  el.style.left = L.x + "px";
  el.style.top = L.y + "px";
  el.style.width = L.w + "px";
  if (L.h) el.style.height = L.h + "px";
  world.appendChild(el);
}

function makeTerminal(id, title) {
  const el = document.createElement("div");
  el.className = "tile terminal";
  el.innerHTML = `
    <div class="titlebar">
      <div class="lights"><i></i><i></i><i></i></div>
      <div class="title">${title}</div>
      <div class="status idle"><span class="dot"></span><span class="label"></span></div>
    </div>
    <div class="screen"></div>`;
  place(el, id);
  const t = {
    el,
    screen: el.querySelector(".screen"),
    status: el.querySelector(".status"),
    setStatus(kind) {
      this.status.className = "status " + kind;
      el.classList.remove("working", "asking");
      if (kind === "working") el.classList.add("working");
      if (kind === "asking") el.classList.add("asking");
    },
    focusRing(on) { el.classList.toggle("focused", on); },
  };
  tiles[id] = t;
  return t;
}

async function appear(id, focusIds) {
  const t = tiles[id];
  if (focusIds) focus(focusIds);
  await sleep(focusIds ? 650 : 80);
  t.el.classList.add("show");
  await sleep(560);
}

function addLine(screen, html, cls = "") {
  const ln = document.createElement("span");
  ln.className = "ln " + cls;
  ln.innerHTML = html;
  screen.appendChild(ln);
  return ln;
}

/* Stream claude-style transcript lines with a small gap between each. */
async function stream(screen, lines) {
  for (const [html, cls, gap] of lines) {
    addLine(screen, html, cls || "");
    await sleep(gap || 360);
  }
}

/* Type into a claude composer box, then echo the message into the transcript. */
async function promptInto(t, text) {
  const composer = document.createElement("div");
  composer.className = "composer";
  composer.innerHTML = `<span class="chev">›</span><span class="typed"></span><span class="caret"></span>`;
  t.screen.appendChild(composer);
  const typed = composer.querySelector(".typed");
  for (const ch of chars(text)) {
    typed.textContent += ch;
    await sleep(34 + Math.random() * 40);
  }
  await sleep(420);
  composer.remove();
  addLine(t.screen, `<span class="dim">› ${text}</span>`);
  await sleep(260);
}

/* ---- Caption + progress ------------------------------------------------ */
function setCaption(text) {
  captionEl.classList.add("swap");
  setTimeout(() => {
    captionEl.textContent = text;
    captionEl.classList.remove("swap");
  }, 250);
}
function setProgress(frac) {
  progressEl.style.width = Math.round(frac * 100) + "%";
}

/* ---- The Log card ------------------------------------------------------ */
const LOG_ITEMS = [
  "Scaffold the launch-party site",
  "Drop in the poster art",
  "Build hero + RSVP button",
  "Add the lineup",
  "Run it locally",
];
function makeLog() {
  const el = document.createElement("div");
  el.className = "tile log";
  el.innerHTML = `
    <div class="log-head"><span class="chev">›</span><span class="name">Launch party</span><span class="tag">LOG</span></div>
    <hr/>
    <div class="section">Party site</div>
    <div class="items"></div>
    <div class="log-foot"><span class="count">[0/${LOG_ITEMS.length}]</span><div class="track"><div class="fill"></div></div></div>`;
  place(el, "log");
  const itemsEl = el.querySelector(".items");
  LOG_ITEMS.forEach((text) => {
    const row = document.createElement("div");
    row.className = "item";
    row.innerHTML = `<div class="box"></div><div class="label">${text}</div>`;
    itemsEl.appendChild(row);
  });
  tiles.log = {
    el,
    rows: [...itemsEl.children],
    done: 0,
    setActive(i) { this.rows.forEach((r, k) => r.classList.toggle("active", k === i)); },
    check(i) {
      const r = this.rows[i];
      r.classList.remove("active");
      r.classList.add("done");
      this.done++;
      el.querySelector(".count").textContent = `[${this.done}/${LOG_ITEMS.length}]`;
      el.querySelector(".fill").style.width = (this.done / LOG_ITEMS.length) * 100 + "%";
      if (i + 1 < this.rows.length) this.setActive(i + 1);
    },
  };
  return tiles.log;
}

/* ---- Image + browser tiles -------------------------------------------- */
function makeCat() {
  const el = document.createElement("div");
  el.className = "tile image-tile";
  el.innerHTML = `<img src="assets/party.svg" alt="Disco ball" />`;
  place(el, "cat");
  tiles.cat = { el, link() { el.classList.add("linked"); } };
  return tiles.cat;
}
function makeBrowser() {
  const el = document.createElement("div");
  el.className = "tile browser";
  el.innerHTML = `
    <div class="chrome">
      <div class="dots"><i></i><i></i><i></i></div>
      <div class="url">localhost:5173 — launch party</div>
    </div>
    <div class="page">
      <div class="catsite">
        <img src="assets/party.svg" alt="disco ball"/>
        <h1>You're invited.</h1>
        <p>Doors at 9. Bring your terminals — confetti, neon, and a very good playlist provided.</p>
        <div class="adopt">RSVP →</div>
        <div class="strip"><span></span><span></span><span></span><span></span></div>
      </div>
    </div>`;
  place(el, "browser");
  tiles.browser = { el, render() { el.querySelector(".catsite").classList.add("show"); } };
  return tiles.browser;
}

/* ---- Edge glow --------------------------------------------------------- */
const setGlow = (on) => edgeGlow.classList.toggle("on", on);

/* ---- The story --------------------------------------------------------- */
async function play() {
  // Beat 1 — a single terminal.
  setProgress(0.05);
  setCaption("It starts with a single terminal.");
  const t1 = makeTerminal("t1", "claude");
  await appear("t1", ["t1"]);

  // Beat 2 — prompt into it.
  setCaption("Prompt your agent like you always would.");
  await stream(t1.screen, [[`<span class="bullet">●</span> <span class="dim">claude — ready in ~/launch-party</span>`, "", 500]]);
  await promptInto(t1, "set up my launch-party site and keep a Log of the work");
  t1.setStatus("working");
  await stream(t1.screen, [
    [`<span class="bullet">●</span> On it. Spinning up a project and a shared Log.`, "", 520],
    [`  <span class="tool">New Log <b>Launch party</b></span>`, "", 420],
  ]);

  // Beat 3 — connect a Log; items tick.
  setProgress(0.2);
  setCaption("Wire it to a Log — every task ticks off in real time.");
  makeLog();
  focus(["t1", "log"]);
  await sleep(700);
  tiles.log.el.classList.add("show");
  await sleep(520);
  await drawWire("t1", "log");
  tiles.log.setActive(0);
  await sleep(300);
  tiles.log.check(0);          // scaffold
  t1.setStatus("idle");

  // Beat 4 — drop in a cat image.
  setProgress(0.33);
  setCaption("Drop in an image. Connected tiles become context the agent can read.");
  makeCat();
  focus(["t1", "log", "cat"]);
  await sleep(750);
  tiles.cat.el.classList.add("show");
  await sleep(520);

  // Beat 5 — open a second agent and ask for the site.
  setProgress(0.45);
  setCaption("Spin up another agent — they share the same canvas.");
  const t2 = makeTerminal("t2", "claude ✻ party-site");
  focus(["t1", "log", "cat", "t2"]);
  await sleep(120);
  t2.el.classList.add("show");
  await sleep(620);
  await drawWire("cat", "t2");
  tiles.cat.link();
  await drawWire("log", "t2");
  await promptInto(t2, "make a party website");

  // Beat 6 — output mocks out.
  setCaption("Watch the work stream out, tile by tile.");
  t2.setStatus("working");
  tiles.log.setActive(1);
  await stream(t2.screen, [
    [`<span class="bullet">●</span> A neon one-pager for the party. Reading your art…`, "", 520],
    [`  <span class="tool">Read   <b>party.svg</b> <span class="faint">(linked image)</span></span>`, "", 460],
  ]);
  tiles.log.check(1);          // pulled photo in
  await stream(t2.screen, [
    [`  <span class="tool">Write  <span class="path">index.html</span></span>`, "", 380],
    [`  <span class="tool">Write  <span class="path">styles.css</span></span>`, "", 380],
    [`  <span class="tool">Write  <span class="path">party.svg</span></span>`, "", 380],
    [`<span class="spin">✶</span> <span class="dim">Styling the hero… <span class="faint">(esc to interrupt)</span></span>`, "", 900],
  ]);
  tiles.log.check(2);          // hero + adopt
  await sleep(200);
  tiles.log.check(3);          // gallery
  await stream(t2.screen, [
    [`<span class="bullet">●</span> Done — hero, the lineup, and an RSVP button.`, "", 420],
    [`  <span class="dim">Want me to run it?</span>`, "", 480],
  ]);
  t2.setStatus("idle");

  // Beat 7 — a terminal runs the site; preview renders.
  setProgress(0.62);
  setCaption("Run the result right next to the code.");
  const t3 = makeTerminal("t3", "zsh — ~/launch-party");
  focus(["t2", "t3"]);
  await sleep(680);
  t3.el.classList.add("show");
  await sleep(420);
  await drawWire("t2", "t3", { dashed: true });
  await promptInto2(t3, "python3 -m http.server 5173");
  t3.setStatus("working");
  await stream(t3.screen, [
    [`<span class="dim">Serving HTTP on :: port 5173 (http://[::]:5173/) …</span>`, "", 560],
    [`<span class="faint">[15/Jun 14:02] "GET / HTTP/1.1" 200 -</span>`, "", 240],
    [`<span class="faint">[15/Jun 14:02] "GET /styles.css HTTP/1.1" 200 -</span>`, "", 240],
  ]);
  makeBrowser();
  focus(["t3", "browser"]);
  await sleep(720);
  tiles.browser.el.classList.add("show");
  await sleep(360);
  tiles.browser.render();
  await sleep(300);
  tiles.log.check(4);          // run it locally
  t3.setStatus("idle");
  await sleep(700);

  // Beat 8 — an off-screen agent needs you; the edge lights up.
  setProgress(0.8);
  setCaption("Another agent needs you — the canvas edge lights up, even off-screen.");
  const t4 = makeTerminal("t4", "claude ✻ deploy");
  t4.el.classList.add("show");
  t4.setStatus("working");
  // keep the camera where it is; t4 is off to the right.
  await sleep(900);
  await stream(t4.screen, [
    [`<span class="bullet">●</span> The party site is live locally.`, "", 500],
  ]);
  t4.setStatus("asking");
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.innerHTML =
    `<span class="dim">Want me to deploy it?</span>` +
    `<span class="opt sel"><span class="arrow">❯ </span>1. Deploy to Vercel</span>` +
    `<span class="opt"><span class="arrow">❯ </span>2. Push to GitHub Pages</span>` +
    `<span class="opt"><span class="arrow">❯ </span>3. Leave it running here</span>` +
    `<span class="footer">↑↓ to navigate · enter to select</span>`;
  t4.screen.appendChild(menu);
  setGlow(true);
  await sleep(1600);

  // Beat 9 — scroll over to reveal the waiting prompt.
  setProgress(0.95);
  setCaption("Scroll over. It's waiting on an answer.");
  focus(["t4"], { maxScale: 0.95 });
  await sleep(900);
  setGlow(false);
  t4.focusRing(true);
  await sleep(4200);

  // Settle — pull back to the whole canvas.
  setProgress(1);
  setCaption("pty.party — wire up your terminals, notes, and agents on one canvas.");
  t4.focusRing(false);
  focus(["t1", "log", "cat", "t2", "t3", "browser"], { maxScale: 0.7 });
  await sleep(4200);
}

/* A plain-shell composer: a "~/dir ❯ " prompt with the command typed in. */
async function promptInto2(t, cmd) {
  const line = document.createElement("span");
  line.className = "ln";
  line.innerHTML = `<span class="ok">~/launch-party ❯</span> <span class="typed"></span><span class="caret"></span>`;
  t.screen.appendChild(line);
  const typed = line.querySelector(".typed");
  for (const ch of chars(cmd)) {
    typed.textContent += ch;
    await sleep(30 + Math.random() * 36);
  }
  await sleep(360);
  line.querySelector(".caret").remove();
}

/* ---- Run / replay ------------------------------------------------------ */
function reset() {
  for (const id of Object.keys(tiles)) delete tiles[id];
  [...world.querySelectorAll(".tile")].forEach((n) => n.remove());
  wires.innerHTML = "";
  setGlow(false);
  setProgress(0);
  camera = { x: 0, y: 0, s: 1 };
  applyCamera(false);
}

async function start() {
  runToken++;
  reset();
  // center the (empty) canvas where t1 will appear before the first beat
  focus(["t1"], { animate: false });
  try {
    await play();
  } catch (e) {
    if (e !== "cancel") console.error(e);
  }
}

replayBtn.addEventListener("click", start);

/* The canvas is a hands-off cinematic: the camera is driven entirely by the
   timeline, so manual pan/scroll/zoom are intentionally not wired up. Block the
   page from scrolling on a trackpad/wheel so only the script moves the view. */
viewport.addEventListener("wheel", (e) => e.preventDefault(), { passive: false });

window.addEventListener("resize", () => focus(lastFocus, { animate: false }));

/* Kick off once fonts/layout settle. */
window.addEventListener("load", () => setTimeout(start, 300));
