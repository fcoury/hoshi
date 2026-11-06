#!/usr/bin/env node
// Cuts the App Preview from the takes recorded by preview.sh and the title
// cards exported by `bun run export -- --cards`.
//
//   node scripts/screenshots/compose-preview.mjs [device]
//   -> assets/app-preview/iphone-6.9.mp4  (886x1920, 30 fps, H.264, AAC)
//
// Segments are placed relative to each take's marks and touches (see
// <take>.json), so a re-recorded take lines up without retiming. Taps logged
// by preview.sh land when AXe returns, i.e. just after the finger lands.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const device = process.argv[2] ?? "iphone-6.3";
const takesDir = join(root, ".shots", "preview", device);
const cardsDir = join(root, ".shots", "preview", "cards");
const outDir = join(root, "assets", "app-preview");
const out = join(outDir, "iphone-6.9.mp4");

// Output: App Preview size for 6.9"/6.5" iPhones. Captures are 1206x2622
// (iPhone 17 Pro); scale to 886 wide and trim the 6 px of extra height.
const W = 886, H = 1920, FPS = 30;
const SRC_W = 1206, SRC_H = 2622;
const S = W / SRC_W;                       // capture px -> output px
const SCALED_H = Math.round(SRC_H * S);    // 1926
const CROP_Y = Math.floor((SCALED_H - H) / 2);
const PT = 3 * S;                          // points -> output px
const FADE = 0.3;                          // card crossfades
const DOT = 92;                            // touch dot diameter (px)

const take = (name) => JSON.parse(readFileSync(join(takesDir, `${name}.json`), "utf8"));
const A = take("agents"), T = take("terminal");
const taps = (t) => t.touches.filter((x) => x.kind === "tap");
const downs = (t) => t.touches.filter((x) => x.kind !== "tap");
const [aList, aBuilder, aLock, aField, aSend] = taps(A).map((x) => x.t);
const [tHoshi] = taps(T).map((x) => x.t);
const [d0, d1, d2, up] = downs(T).map((x) => x.t);
void tHoshi;

// One entry per piece of the video, in order. Footage pieces list their
// segments: [take, start, end, speed]. Consecutive footage cuts hard; cards
// crossfade in and out.
const PLAN = [
  { card: "intro", dur: 1.7 },
  { footage: [
    ["agents", aList - 1.2, aList + 0.4],          // server list, tap devbox
    ["agents", aBuilder - 1.3, aBuilder + 0.25],   // picker: three agents, tap Builder
    ["agents", aBuilder + 0.3, aBuilder + 1.0],    // builder pane appears
    ["agents", A.marks.builder - 0.1, A.marks.builder + 3.6], // work streams in
  ] },
  { card: "agents", dur: 1.3 },
  { footage: [
    ["agents", A.marks.lock - 0.2, A.marks.lock + 1.7],   // Lock Screen Live Activity
    ["agents", aLock - 0.9, aLock + 1.1],                 // Reply opens Hoshi on the agent
    ["agents", aField - 0.5, aField + 0.2],               // focus the composer
    ["agents", aField + 0.2, aSend - 0.3, 3.2],           // typing, sped up
    ["agents", aSend - 0.3, aSend + 2.6],                 // send: the agent carries on
  ] },
  { card: "terminal", dur: 1.3 },
  { footage: [
    ["terminal", T.marks.tmux - 1.6, T.marks.tmux],       // tmux, git log
    ["terminal", d0 - 0.3, d0 + 0.9],                     // hold: joystick appears
    ["terminal", d1 - 0.2, d1 + 1.0],                     // push right: cursor moves
    ["terminal", d2 - 0.2, d2 + 1.1],                     // push down: scrolls
  ] },
  { card: "outro", dur: 2.4 },
];
void up;

// Touch dots per take, in take time: [start, end, x, y] in output px.
function dots(t) {
  const list = [];
  for (const x of t.touches.filter((x) => x.kind === "tap")) {
    list.push([x.t - 0.35, x.t + 0.1, x.x, x.y]);
  }
  const holds = t.touches.filter((x) => x.kind !== "tap");
  holds.forEach((x, i) => {
    if (x.kind === "up") return;
    const next = holds[i + 1];
    list.push([x.t - 0.25, next ? next.t - 0.25 : x.t + 1, x.x, x.y]);
  });
  return list.map(([a, b, x, y]) => [a, b, x * PT - DOT / 2, y * PT - CROP_Y - DOT / 2]);
}
const DOTS = { agents: dots(A), terminal: dots(T) };

// ─── pass 1: cut each segment ──────────────────────────────────────────────
// Seeking per segment keeps ffmpeg from buffering the 60 fps native takes.
const r3 = (n) => Math.round(n * 1000) / 1000;
const frames = (d) => Math.round(d * FPS);
const ff = (args) => execFileSync("ffmpeg", ["-loglevel", "error", "-y", ...args], { stdio: "inherit" });
const segDir = join(takesDir, "segments");
mkdirSync(segDir, { recursive: true });
const dotPng = join(segDir, "dot.png");
const c = DOT / 2;
ff(["-f", "lavfi", "-i", `color=c=white@0:s=${DOT}x${DOT},format=rgba,geq=r=255:g=255:b=255:` +
  `a='255*(0.42*lt(hypot(X-${c},Y-${c}),${c - 5})+0.85*between(hypot(X-${c},Y-${c}),${c - 5},${c - 1}))'`,
  "-frames:v", "1", dotPng]);
const MID = ["-c:v", "libx264", "-crf", "8", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-an"];

const pieces = []; // { files: [path], dur }
let n = 0;
for (const piece of PLAN) {
  if (piece.card) {
    const file = join(segDir, `${String(n++).padStart(2, "0")}-${piece.card}.mp4`);
    ff(["-loop", "1", "-framerate", String(FPS), "-i", join(cardsDir, `${piece.card}.png`),
      "-vf", `scale=${W}:${H},setsar=1,format=yuv420p`, "-frames:v", String(frames(piece.dur)), ...MID, file]);
    pieces.push({ files: [file], dur: frames(piece.dur) / FPS });
    continue;
  }
  const files = [];
  let total = 0;
  for (const [name, a, b, speed = 1] of piece.footage) {
    const dur = (b - a) / speed;
    const file = join(segDir, `${String(n++).padStart(2, "0")}-${name}.mp4`);
    let chain = `[0]setpts=(PTS-STARTPTS)/${speed},fps=${FPS},scale=${W}:${SCALED_H}:flags=lanczos,` +
      `crop=${W}:${H}:0:${CROP_Y},setsar=1,format=yuv420p[v0]`;
    let last = "v0", k = 0;
    for (const [da, db, x, y] of DOTS[name]) {
      if (db < a || da > b) continue;
      const s0 = r3(Math.max(0, (da - a) / speed)), s1 = r3(Math.min(dur, (db - a) / speed));
      chain += `;[${last}][1]overlay=x=${r3(x)}:y=${r3(y)}:enable='between(t,${s0},${s1})'[o${k}]`;
      last = `o${k++}`;
    }
    ff(["-ss", String(r3(a)), "-t", String(r3(b - a + 0.5)), "-i", join(takesDir, `${name}.mov`),
      "-loop", "1", "-i", dotPng, "-filter_complex", chain, "-map", `[${last}]`,
      "-frames:v", String(frames(dur)), ...MID, file]);
    files.push(file);
    total += frames(dur) / FPS;
  }
  pieces.push({ files, dur: total });
}

// ─── pass 2: join, crossfade, encode ───────────────────────────────────────
const inputs = [], f = [];
let idx = 0;
const labels = pieces.map((p, i) => {
  const ins = p.files.map((file) => (inputs.push("-i", file), idx++));
  const l = `p${i}`;
  f.push(`${ins.map((j) => `[${j}]`).join("")}concat=n=${ins.length}:v=1:a=0,settb=1/${FPS},fps=${FPS}[${l}]`);
  return l;
});
let acc = labels[0], accDur = pieces[0].dur;
pieces.slice(1).forEach((p, i) => {
  const l = `x${i}`;
  f.push(`[${acc}][${labels[i + 1]}]xfade=transition=fade:duration=${FADE}:offset=${r3(accDur - FADE)}[${l}]`);
  acc = l;
  accDur += p.dur - FADE;
});
console.log(`duration ${accDur.toFixed(2)}s`);
if (accDur > 30 || accDur < 15) throw new Error(`App Previews must be 15-30 s, got ${accDur.toFixed(2)}`);

// Silent stereo track: App Store Connect expects audio in the container.
inputs.push("-f", "lavfi", "-t", String(r3(accDur)), "-i", "anullsrc=channel_layout=stereo:sample_rate=48000");
mkdirSync(outDir, { recursive: true });
ff([...inputs, "-filter_complex", f.join(";"),
  "-map", `[${acc}]`, "-map", `${idx}:a`,
  "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-pix_fmt", "yuv420p",
  "-r", String(FPS), "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M", "-preset", "slow",
  "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-shortest",
  "-movflags", "+faststart", out]);
console.log(`wrote ${out}`);
