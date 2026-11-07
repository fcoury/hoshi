#!/usr/bin/env node
// Cuts the gethoshi.app film: one chapter per wish, each take composited into
// the phone on its stage (exported by `bun run export -- --film`).
//
//   node scripts/screenshots/compose-film.mjs [device]
//   -> assets/site/img/film.mp4         (1920x1080, 30 fps, H.264, no audio)
//   -> assets/site/img/film-poster.jpg
//
// Segments are placed relative to each take's marks and touches (see
// <take>.json), like compose-preview.mjs.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const device = process.argv[2] ?? "iphone-6.3";
const takesDir = join(root, ".shots", "preview", device);
const stagesDir = join(root, ".shots", "preview", "film");
const workDir = join(takesDir, "film-segments");
const outDir = join(root, "assets", "site", "img");

const H = 1080, FPS = 30;
const SRC_W = 1206, SRC_H = 2622;

// Mirrors FILM_PHONE / FILM_ZOOM in assets/screenshot-generator/src/slides/film.tsx.
const PHONE = { x: 1240, width: 468 };
const bezel = PHONE.width * 0.028;
const screenW = PHONE.width - bezel * 2;
const screenH = screenW * (SRC_H / SRC_W);
const SX = Math.round(PHONE.x + bezel);
const SY = Math.round((H - (screenH + bezel * 2)) / 2 + bezel);
const SW = Math.round(screenW), SH = Math.round(screenH);
const RADIUS = screenW * 0.137;
const ZOOM = { x: 150, y: 846, w: 840, h: 90 };
const KEYBAR = { y: 2493, h: Math.round((SRC_W * ZOOM.h) / ZOOM.w) }; // capture rows of the key bar

const PT = SW / (SRC_W / 3); // points -> screen px
const DOT = 46;
const FADE = 0.4;  // between chapters
const LEAD = 0.9;  // first frame held while the stage text is read
const TAIL = 0.5;  // last frame held

const take = (name) => JSON.parse(readFileSync(join(takesDir, `${name}.json`), "utf8"));
const TAKES = Object.fromEntries(
  ["hack", "mosh", "terminal", "codex", "keysets", "custom-add", "custom-use", "themes"].map((n) => [n, take(n)]),
);
const m = (n) => TAKES[n].marks;
const downs = TAKES.terminal.touches.filter((x) => x.kind !== "tap").map((x) => x.t);

// One entry per chapter. Footage chapters list segments: [take, start, end, speed].
const PLAN = [
  { stage: "intro", dur: 2.8 },
  { stage: "source", footage: [
    ["hack", m("hack").vim - 0.4, m("hack").edit + 0.2, 1.25],   // vim: retitle the README
    ["hack", m("hack").edit + 0.2, m("hack").commit, 3],         // :wq, git commit, sped up
    ["hack", m("hack").commit, m("hack").end, 1],                // git log
  ] },
  { stage: "price", dur: 3.4 },
  { stage: "mosh", footage: [
    ["mosh", m("mosh").stream - 0.4, m("mosh").drop - 0.7, 1],     // training streams on gpu-box
    ["mosh", m("mosh").drop - 0.7, m("mosh").drop + 2.6, 1],      // network drops: Reconnecting
    ["mosh", m("mosh").drop + 2.6, m("mosh").back - 0.8, 8],      // 20 s offline, sped up
    ["mosh", m("mosh").back - 0.8, m("mosh").back + 3.2, 1],      // back: Mosh catches up
  ] },
  { stage: "tmux", footage: [
    ["terminal", m("terminal").tmux - 4.4, m("terminal").tmux + 1.1, 1], // pick the session, land in tmux
  ] },
  { stage: "herdr", footage: [
    ["codex", m("codex").picker - 0.2, m("codex").codex + 0.3, 1],   // Herdr agents, open Codex
    ["codex", m("codex").codex + 0.3, m("codex").codex + 8.6, 2],    // Codex answers, sped up
    ["codex", m("codex").codex + 8.6, m("codex").codex + 10.8, 1],
  ] },
  { stage: "app-keys", zoom: true, footage: [
    ["keysets", m("keysets").shell - 0.2, m("keysets").vim + 2, 1.3],   // shell -> vim
    ["keysets", m("keysets").less - 1.3, m("keysets").less + 2.4, 1.2], // less
    ["keysets", m("keysets").codex - 1.4, m("keysets").end, 1.1],       // codex
  ] },
  { stage: "my-keys", footage: [
    ["custom-add", m("custom-add").list, m("custom-add").end - 1.5, 3.2], // Settings > toolbar > new key
    ["custom-use", m("custom-use").shell + 0.3, m("custom-use").end - 0.2, 1], // tap git st
  ] },
  { stage: "joystick", footage: [
    ["terminal", downs[0] - 0.4, downs[3] - 0.4, 1.3], // hold, push right, push down
  ] },
  { stage: "themes", footage: [
    ["themes", m("themes").before + 1.5, m("themes").after, 3], // Settings: theme, then font
    ["themes", m("themes").after, m("themes").end, 1],         // the result
  ] },
  { stage: "outro", dur: 3.2 },
];

// Touch dots per take, in take time: [start, end, x, y] in screen px.
function dots(t) {
  const list = [];
  for (const x of t.touches.filter((x) => x.kind === "tap")) list.push([x.t - 0.35, x.t + 0.1, x.x, x.y]);
  const holds = t.touches.filter((x) => x.kind !== "tap");
  holds.forEach((x, i) => {
    if (x.kind === "up") return;
    const next = holds[i + 1];
    list.push([x.t - 0.25, next ? next.t - 0.25 : x.t + 1, x.x, x.y]);
  });
  return list.map(([a, b, x, y]) => [a, b, x * PT - DOT / 2, y * PT - DOT / 2]);
}

const r3 = (n) => Math.round(n * 1000) / 1000;
const frames = (d) => Math.round(d * FPS);
const ff = (args) => execFileSync("ffmpeg", ["-loglevel", "error", "-y", ...args], { stdio: "inherit" });
const MID = ["-c:v", "libx264", "-crf", "10", "-preset", "veryfast", "-an"];

rmSync(workDir, { recursive: true, force: true });
mkdirSync(workDir, { recursive: true });

// Touch dot and the screen's rounded-corner mask.
const dotPng = join(workDir, "dot.png");
const c = DOT / 2;
ff(["-f", "lavfi", "-i", `color=c=white@0:s=${DOT}x${DOT},format=rgba,geq=r=255:g=255:b=255:` +
  `a='255*(0.42*lt(hypot(X-${c},Y-${c}),${c - 4})+0.85*between(hypot(X-${c},Y-${c}),${c - 4},${c - 1}))'`,
  "-frames:v", "1", dotPng]);
const maskPng = join(workDir, "mask.png");
const R = r3(RADIUS);
ff(["-f", "lavfi", "-i", `color=c=black:s=${SW}x${SH},format=gray,geq=lum='clip((${R}+0.5-hypot(max(max(${R}-X,X-(W-1-${R})),0),max(max(${R}-Y,Y-(H-1-${R})),0)))*255,0,255)'`,
  "-frames:v", "1", maskPng]);

// ─── pass 1: cut each segment to screen size (and the key bar strip) ─────────
let n = 0;
const chapters = []; // { file, dur }
for (const ch of PLAN) {
  const stage = join(stagesDir, `${ch.stage}.png`);
  const out = join(workDir, `ch-${String(chapters.length).padStart(2, "0")}-${ch.stage}.mp4`);

  if (!ch.footage) {
    ff(["-loop", "1", "-framerate", String(FPS), "-i", stage,
      "-vf", "format=yuv420p", "-frames:v", String(frames(ch.dur)), ...MID, out]);
    chapters.push({ file: out, dur: frames(ch.dur) / FPS });
    continue;
  }

  const screens = [], strips = [];
  let total = 0;
  for (const [name, a, b, speed = 1] of ch.footage) {
    const dur = (b - a) / speed;
    const id = String(n++).padStart(2, "0");
    const screen = join(workDir, `${id}-${name}.mp4`);
    const strip = join(workDir, `${id}-${name}-bar.mp4`);
    let chain = `[0]setpts=(PTS-STARTPTS)/${speed},fps=${FPS},split[raw][rawbar];` +
      `[raw]scale=${SW}:${SH}:flags=lanczos,setsar=1[v0]`;
    let last = "v0", k = 0;
    for (const [da, db, x, y] of dots(TAKES[name])) {
      if (db < a || da > b) continue;
      const s0 = r3(Math.max(0, (da - a) / speed)), s1 = r3(Math.min(dur, (db - a) / speed));
      chain += `;[${last}][1]overlay=x=${r3(x)}:y=${r3(y)}:enable='between(t,${s0},${s1})'[o${k}]`;
      last = `o${k++}`;
    }
    chain += `;[${last}]format=yuv444p[scr]`;
    chain += `;[rawbar]crop=${SRC_W}:${KEYBAR.h}:0:${KEYBAR.y},scale=${ZOOM.w}:${ZOOM.h}:flags=lanczos,setsar=1,format=yuv444p[bar]`;
    ff(["-ss", String(r3(a)), "-t", String(r3(b - a + 0.5)), "-i", join(takesDir, `${name}.mov`),
      "-loop", "1", "-i", dotPng, "-filter_complex", chain,
      "-map", "[scr]", "-frames:v", String(frames(dur)), ...MID, screen,
      "-map", "[bar]", "-frames:v", String(frames(dur)), ...MID, strip]);
    screens.push(screen);
    strips.push(strip);
    total += frames(dur) / FPS;
  }

  // ─── pass 2: put the chapter's footage on its stage ──────────────────────
  const dur = total + LEAD + TAIL;
  const inputs = ["-loop", "1", "-framerate", String(FPS), "-i", stage, "-loop", "1", "-i", maskPng];
  const files = [...screens, ...(ch.zoom ? strips : [])];
  for (const f of files) inputs.push("-i", f);
  const pad = `tpad=start_duration=${LEAD}:start_mode=clone:stop_duration=${TAIL}:stop_mode=clone`;
  const ins = (from, count) => Array.from({ length: count }, (_, i) => `[${from + i}]`).join("");
  let f = `${ins(2, screens.length)}concat=n=${screens.length}:v=1:a=0,${pad},format=yuva444p[s];` +
    `[1]format=gray,scale=${SW}:${SH}[m];[s][m]alphamerge[sm];` +
    `[0]format=yuv444p[bg];[bg][sm]overlay=x=${SX}:y=${SY}:shortest=0[p]`;
  let last = "p";
  if (ch.zoom) {
    f += `;${ins(2 + screens.length, strips.length)}concat=n=${strips.length}:v=1:a=0,${pad}[z];` +
      `[p][z]overlay=x=${ZOOM.x}:y=${ZOOM.y}[pz]`;
    last = "pz";
  }
  f += `;[${last}]format=yuv420p[out]`;
  ff([...inputs, "-filter_complex", f, "-map", "[out]", "-frames:v", String(frames(dur)), "-r", String(FPS), ...MID, out]);
  chapters.push({ file: out, dur: frames(dur) / FPS });
}

// ─── pass 3: crossfade the chapters and encode for the web ─────────────────
const inputs = [], f = [];
chapters.forEach((ch) => inputs.push("-i", ch.file));
let acc = "0:v", accDur = chapters[0].dur;
chapters.slice(1).forEach((ch, i) => {
  const l = `x${i}`;
  f.push(`[${i === 0 ? "0:v" : acc}][${i + 1}:v]xfade=transition=fade:duration=${FADE}:offset=${r3(accDur - FADE)}[${l}]`);
  acc = l;
  accDur += ch.dur - FADE;
});
console.log(`duration ${accDur.toFixed(2)}s`);
// Chapter starts, for the site's chapter markers (data-t).
let at = 0;
console.log("chapters " + PLAN.map((ch, i) => { const s = `${ch.stage}=${at.toFixed(1)}`; at += chapters[i].dur - FADE; return s; }).join(" "));

mkdirSync(outDir, { recursive: true });
const out = join(outDir, "film.mp4");
ff([...inputs, "-filter_complex", f.join(";") + `;[${acc}]format=yuv420p[v]`, "-map", "[v]",
  "-c:v", "libx264", "-profile:v", "high", "-crf", "24", "-preset", "slow",
  "-r", String(FPS), "-an", "-movflags", "+faststart", out]);
ff(["-i", join(stagesDir, "poster.png"), "-vf", "scale=1280:-2", "-q:v", "3", "-frames:v", "1", "-update", "1",
  join(outDir, "film-poster.jpg")]);
console.log(`wrote ${out}`);
