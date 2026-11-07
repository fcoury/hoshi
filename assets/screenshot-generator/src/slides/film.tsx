// Stages for the gethoshi.app film, 1920x1080. Exported by
// `bun run export -- --film` to .shots/preview/film/<id>.png; the takes are
// composited into the phone's screen by scripts/screenshots/compose-film.mjs,
// which mirrors FILM_PHONE below.
import type { CSSProperties, ReactNode } from "react";
import { CANVAS, CAPTURE } from "@/lib/brand";

const { w: W, h: H } = CANVAS.film;

// Site tokens (assets/site/index.html).
const SKY = { top: "#0a0d29", mid: "#141a46", low: "#2a215f", glow: "242, 163, 124" };
const STAR = "#ffdf8a";
const TEXT = "#eceaf8";
const MUTED = "#abaed6";
const DISPLAY = "var(--font-fraunces), Georgia, serif";
const HAND = "var(--font-hand), 'Marker Felt', cursive";
const MONO = "var(--font-mono), 'JetBrains Mono', ui-monospace, monospace";
const BODY = "var(--font-inter), sans-serif";
const SOFT: CSSProperties = { fontVariationSettings: "'SOFT' 100, 'WONK' 1" };

/** Phone frame geometry, shared with compose-film.mjs. */
export const FILM_PHONE = { x: 1240, width: 468 } as const;
const bezel = FILM_PHONE.width * 0.028;
const screenW = FILM_PHONE.width - bezel * 2;
const screenH = screenW * (CAPTURE.iphone.h / CAPTURE.iphone.w);
const phoneH = screenH + bezel * 2;
const phoneTop = (H - phoneH) / 2;

/** Magnified key bar (capture rows KEYBAR_CROP), also mirrored by compose-film.mjs. */
export const FILM_ZOOM = { x: 150, y: 846, w: 840, h: 90 } as const;

function stars(n: number, seed: number) {
  let s = seed;
  const r = () => (s = (s * 16807) % 2147483647) / 2147483647;
  return Array.from({ length: n }, () => ({
    x: r() * W,
    y: r() * H,
    r: r() * 1.3 + 0.3,
    o: 0.2 + r() * 0.7,
    warm: r() < 0.2,
  }));
}

const STAR_PATH =
  "M12 1.8c.5 0 .9.3 1.1.8l2.3 5.6 6 .5c1 .1 1.4 1.3.7 2l-4.6 3.9 1.4 5.9c.2 1-.8 1.7-1.7 1.2L12 18.6l-5.2 3.1c-.9.5-1.9-.2-1.7-1.2l1.4-5.9L1.9 10.7c-.7-.7-.3-1.9.7-2l6-.5 2.3-5.6c.2-.5.6-.8 1.1-.8z";

function Star({ size, color = STAR, style }: { size: number; color?: string; style?: CSSProperties }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flex: "none", ...style }}>
      <path fill={color} d={STAR_PATH} />
    </svg>
  );
}

function Sky({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        position: "relative",
        width: W,
        height: H,
        overflow: "hidden",
        color: TEXT,
        background: `radial-gradient(ellipse 1300px 520px at 40% 120%, rgba(${SKY.glow},.42), rgba(${SKY.glow},.10) 55%, transparent 75%),
          radial-gradient(ellipse 760px 600px at 78% 30%, rgba(120,110,255,.16), transparent 70%),
          linear-gradient(180deg, ${SKY.top} 0%, ${SKY.mid} 58%, ${SKY.low} 100%)`,
      }}
    >
      <svg width={W} height={H} style={{ position: "absolute", inset: 0 }}>
        {stars(340, 11).map((s, i) => (
          <circle key={i} cx={s.x} cy={s.y} r={s.r} fill={s.warm ? STAR : "#dfe4ff"} opacity={s.o} />
        ))}
      </svg>
      {children}
    </div>
  );
}

/** Empty phone; compose-film.mjs drops the take into the screen. */
function Phone() {
  return (
    <div
      style={{
        position: "absolute",
        left: FILM_PHONE.x,
        top: phoneTop,
        width: FILM_PHONE.width,
        height: phoneH,
        padding: bezel,
        borderRadius: screenW * 0.137 + bezel,
        background: "linear-gradient(145deg, #3a3f4a 0%, #1b1e25 35%, #2b2f38 70%, #14161b 100%)",
        boxShadow: "0 60px 120px -30px rgba(0,0,0,.85), 0 0 160px rgba(255,223,138,.10)",
      }}
    >
      <div style={{ width: screenW, height: screenH, borderRadius: screenW * 0.137, background: "#000" }} />
    </div>
  );
}

const Granted = () => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      gap: 10,
      alignSelf: "flex-start",
      padding: "8px 20px",
      borderRadius: 999,
      border: `2px solid ${STAR}`,
      color: STAR,
      fontFamily: HAND,
      fontWeight: 700,
      fontSize: 26,
      transform: "rotate(-3deg)",
    }}
  >
    Granted <span>✦</span>
  </span>
);

function Zoom() {
  const pad = 10;
  return (
    <div style={{ position: "absolute", left: FILM_ZOOM.x - pad, top: FILM_ZOOM.y - pad, width: FILM_ZOOM.w + pad * 2, height: FILM_ZOOM.h + pad * 2, borderRadius: 22, background: "#000", border: "1.5px solid rgba(255,223,138,.45)", boxShadow: "0 30px 60px -20px rgba(0,0,0,.8)" }}>
      <div style={{ position: "absolute", left: 18, top: -40, fontFamily: HAND, fontSize: 24, color: STAR }}>the key bar, up close ↓</div>
    </div>
  );
}

function Wish({ n, quote, body, phone = true, zoom = false, children }: { n: number; quote: ReactNode; body: ReactNode; phone?: boolean; zoom?: boolean; children?: ReactNode }) {
  return (
    <Sky>
      {zoom && <Zoom />}
      <div style={{ position: "absolute", left: 150, top: 0, bottom: 0, width: 900, display: "flex", flexDirection: "column", justifyContent: "center", gap: 30 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, fontFamily: MONO, fontSize: 26, fontWeight: 500, color: STAR, letterSpacing: "0.04em" }}>
          <Star size={26} /> wish nº {n} <span style={{ color: MUTED, opacity: 0.6 }}>/ 9</span>
        </div>
        <div style={{ fontFamily: HAND, fontSize: 64, lineHeight: 1.18, fontWeight: 500 }}>
          <span style={{ color: STAR }}>I wish </span>
          {quote}
        </div>
        <Granted />
        <div style={{ fontFamily: BODY, fontSize: 30, lineHeight: 1.45, color: MUTED, maxWidth: 820 }}>{body}</div>
        {children}
      </div>
      {phone && <Phone />}
    </Sky>
  );
}

const B = ({ children }: { children: ReactNode }) => <b style={{ color: TEXT, fontWeight: 600 }}>{children}</b>;

function Intro({ poster = false }: { poster?: boolean }) {
  return (
    <Sky>
      <div style={{ position: "absolute", inset: 0, bottom: poster ? 300 : 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 34, textAlign: "center" }}>
        <img src="/app-icon.png" alt="" style={{ width: 170, height: 170, borderRadius: 40, boxShadow: "0 30px 80px -20px rgba(0,0,0,.8), 0 0 120px rgba(255,223,138,.18)" }} />
        <div style={{ fontFamily: HAND, fontSize: 40, color: MUTED }}>my terminal wishes</div>
        <div style={{ fontFamily: DISPLAY, fontWeight: 600, fontSize: 120, lineHeight: 1, letterSpacing: "-0.02em", ...SOFT }}>
          Nine wishes, <em style={{ color: STAR, fontWeight: 500 }}>granted.</em>
        </div>
        <div style={{ fontFamily: BODY, fontSize: 32, color: MUTED }}>The real app, on a real server. No mockups.</div>
      </div>
    </Sky>
  );
}

function Price() {
  return (
    <Wish n={2} phone={false} quote="I paid once and never saw a subscription screen." body={<>No trial, no tiers, no account. <B>$4.99 once</B> gets you every feature in this film and every update after it.</>}>
      <div style={{ position: "absolute", left: 1090, top: 300, width: 620, textAlign: "center" }}>
        <div style={{ fontFamily: DISPLAY, fontWeight: 600, fontSize: 260, lineHeight: 1, color: STAR, letterSpacing: "-0.03em", ...SOFT, textShadow: "0 0 80px rgba(255,223,138,.35)" }}>$4.99</div>
        <div style={{ fontFamily: HAND, fontSize: 56, marginTop: 10 }}>once. that's it.</div>
      </div>
    </Wish>
  );
}

function Outro() {
  return (
    <Sky>
      <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 36, textAlign: "center" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 26, fontFamily: DISPLAY, fontWeight: 600, fontSize: 96, ...SOFT }}>
          <img src="/app-icon.png" alt="" style={{ width: 128, height: 128, borderRadius: 30, boxShadow: "0 20px 60px -16px rgba(0,0,0,.8)" }} />
          Hoshi <span style={{ fontSize: 64, color: STAR, fontWeight: 500 }}>星</span>
        </div>
        <div style={{ fontFamily: HAND, fontSize: 48, color: MUTED }}>the terminal I wished for</div>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "22px 44px", borderRadius: 999, background: STAR, color: SKY.top, fontFamily: BODY, fontWeight: 700, fontSize: 36, boxShadow: "0 0 0 12px rgba(255,223,138,.18), 0 0 80px rgba(255,223,138,.4)" }}>
          <Star size={34} color={SKY.top} /> $4.99 once on the App Store
        </div>
        <div style={{ fontFamily: MONO, fontSize: 26, color: MUTED }}>gethoshi.app</div>
      </div>
    </Sky>
  );
}

export const FILM_STAGES = [
  { id: "intro", C: () => <Intro /> },
  { id: "source", C: () => <Wish n={1} quote="I could read the code, fix what bugs me, and send a PR." body={<>Hoshi is <B>MIT-licensed on GitHub</B>. Here it is editing its own README over Mosh, then committing.</>} /> },
  { id: "price", C: Price },
  { id: "mosh", C: () => <Wish n={3} quote="my session survived the train tunnel." body={<>The GPU box drops off the network for <B>20 seconds</B>. Mosh holds the session and catches up when it's back.</>} /> },
  { id: "tmux", C: () => <Wish n={4} quote="it dropped me straight back into tmux." body={<>Pick a server and you're <B>back in your tmux session</B>, right where you left it.</>} /> },
  { id: "herdr", C: () => <Wish n={5} quote="I could check on my agents from the couch." body={<>Open a <B>Herdr</B> pane and Codex is still working, live on your phone.</>} /> },
  { id: "app-keys", C: () => <Wish zoom n={6} quote="the keyboard knew what I was running." body={<>The key bar <B>changes with the app on screen</B>: shell, vim, less, then Codex.</>} /> },
  { id: "my-keys", C: () => <Wish n={7} quote="I could add the keys I actually use." body={<>Make a <B>git st</B> key that types <code style={{ fontFamily: MONO, color: STAR }}>git status ⏎</code>, then tap it from the front of the bar.</>} /> },
  { id: "joystick", C: () => <Wish n={8} quote="I had arrow keys without hunting for arrow keys." body={<><B>Long-press the arrow key</B> and drag. It's a joystick for vim, less and every prompt.</>} /> },
  { id: "themes", C: () => <Wish n={9} quote="it looked exactly like my desktop." body={<>Nord to <B>Catppuccin Mocha</B>, JetBrains Mono to <B>Victor Mono</B>. Your colors, your font.</>} /> },
  { id: "outro", C: Outro },
  // The site's poster frame: room under the title for the play button.
  { id: "poster", C: () => <Intro poster /> },
] as const;
