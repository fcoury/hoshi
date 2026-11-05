// Headless export of every slide to App Store sizes.
//   bun run export                 -> ../screenshots/<size>/NN-id.png
//   bun run export -- --only iphone/hero
//   bun run export -- --cards      -> ../../.shots/preview/cards/<id>.png
// Starts `next dev` on a private port, screenshots each slide at its design
// size with Playwright, then resizes per App Store display type and strips the
// alpha channel (App Store Connect rejects transparency) with ffmpeg.
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const PORT = 3123;
const outRoot = join(root, "..", "screenshots");
const only = process.argv.includes("--only") ? process.argv[process.argv.indexOf("--only") + 1] : null;

// Mirrors src/lib/brand.ts and the slide registries.
const CANVAS = { iphone: { w: 1320, h: 2868 }, ipad: { w: 2064, h: 2752 }, preview: { w: 886, h: 1920 } };
const CARDS = process.argv.includes("--cards");
const CARDS_OUT = join(root, "..", "..", ".shots", "preview", "cards");
const EXPORTS = {
  // App Store Connect scales the 6.9" set down to every smaller iPhone.
  iphone: [{ name: "iphone-6.9", w: 1320, h: 2868 }],
  ipad: [{ name: "ipad-13", w: 2064, h: 2752 }],
};
const SLIDES = CARDS ? { preview: ["intro", "agents", "terminal", "outro"] } : {
  iphone: ["hero", "lock-screen", "sessions-picker", "mosh", "joystick", "voice", "selection", "sftp", "multi-session", "open-source"],
  ipad: ["hero", "agents", "terminal", "sftp", "sessions", "open-source"],
};

async function waitForServer(url, timeoutMs = 90_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const r = await fetch(url);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server did not start: ${url}`);
}

const server = spawn("bunx", ["next", "dev", "-p", String(PORT)], { cwd: root, stdio: "ignore" });
process.on("exit", () => server.kill());

try {
  await waitForServer(`http://localhost:${PORT}/`);
  // Prefer an installed Google Chrome; fall back to Playwright's own Chromium
  // (`bunx playwright install chromium`) in new headless mode.
  const browser = await chromium
    .launch({ channel: "chrome" })
    .catch(() => chromium.launch({ channel: "chromium" }));
  // A full export replaces the day's set, so dropped slides don't linger.
  if (!only && !CARDS) for (const sizes of Object.values(EXPORTS)) for (const s of sizes) rmSync(join(outRoot, s.name), { recursive: true, force: true });
  const tmp = join(outRoot, ".design");
  mkdirSync(tmp, { recursive: true });

  for (const device of Object.keys(SLIDES)) {
    const { w, h } = CANVAS[device];
    // Cards render at 2x and are downsampled, so small mono text stays crisp.
    const scale = device === "preview" ? 2 : 1;
    const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
    for (const [i, id] of SLIDES[device].entries()) {
      if (only && only !== `${device}/${id}`) continue;
      const name = `${String(i + 1).padStart(2, "0")}-${id}`;
      await page.goto(`http://localhost:${PORT}/?export=${device}/${id}`, { waitUntil: "networkidle" });
      await page.waitForSelector("#slide");
      await page.evaluate(async () => {
        await document.fonts.ready;
        await Promise.all([...document.images].map((img) => img.decode().catch(() => {})));
      });
      const design = join(tmp, `${device}-${name}.png`);
      await page.locator("#slide").screenshot({ path: design });

      if (device === "preview") {
        mkdirSync(CARDS_OUT, { recursive: true });
        execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", design,
          "-vf", `scale=${w}:${h}:flags=lanczos,format=rgb24`, "-frames:v", "1", "-update", "1",
          join(CARDS_OUT, `${id}.png`)]);
        console.log(`cards/${id}.png`);
        continue;
      }
      for (const size of EXPORTS[device]) {
        const dir = join(outRoot, size.name);
        mkdirSync(dir, { recursive: true });
        const out = join(dir, `${name}.png`);
        // Lanczos resize to the exact size; rgb24 drops the alpha channel.
        execFileSync("ffmpeg", [
          "-loglevel", "error", "-y", "-i", design,
          "-vf", `scale=${size.w}:${size.h}:flags=lanczos,format=rgb24`,
          "-frames:v", "1", "-update", "1", out,
        ]);
        console.log(`${size.name}/${name}.png`);
      }
    }
    await page.close();
  }
  await browser.close();
  rmSync(tmp, { recursive: true, force: true });
  console.log(`\nwrote ${outRoot}`);
} finally {
  server.kill();
}
