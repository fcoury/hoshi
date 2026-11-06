// Social card for gethoshi.app (og:image / twitter:image), 1200x630.
// Exported by `bun run export -- --social` to ../site/img/og.jpg.
// Matches the site's wishlist night sky: Fraunces headline, a handwritten
// wish list taped beside the phone (arrow joystick over vim).
import type { CSSProperties } from "react";
import { CANVAS } from "@/lib/brand";
import { Phone } from "@/components/kit";

const { w: W, h: H } = CANVAS.social;
const shot = (name: string) => `/shots/iphone/${name}.png`;

// Site tokens (assets/site/index.html).
const SKY = { top: "#0a0d29", mid: "#141a46", low: "#2a215f", glow: "242, 163, 124" };
const STAR = "#ffdf8a";
const TEXT = "#eceaf8";
const MUTED = "#c3c5e6";
const PAPER = { bg: "#eef0fc", rule: "#cdd3f2", ink: "#27306e", margin: "#d4566e" };
const DISPLAY = "var(--font-fraunces), Georgia, serif";
const HAND = "var(--font-hand), 'Marker Felt', cursive";
const MONO = "var(--font-mono), 'JetBrains Mono', ui-monospace, monospace";
const SOFT: CSSProperties = { fontVariationSettings: "'SOFT' 100, 'WONK' 1" };

const WISHES = [
  "code I can hack",
  "pay once, that's it",
  "mosh!!",
  "tmux & herdr",
  "keys for each app",
  "arrows w/o arrow keys",
  "my themes + fonts",
];

// Seeded starfield, so every export is identical.
function stars(n: number) {
  let s = 7;
  const r = () => (s = (s * 16807) % 2147483647) / 2147483647;
  return Array.from({ length: n }, () => ({
    x: r() * W,
    y: r() * (H - 80),
    r: r() * 1.1 + 0.25,
    o: 0.25 + r() * 0.7,
    warm: r() < 0.2,
  }));
}

const sparkle = (x: number, y: number, k: number) =>
  `M${x} ${y - 2 * k}Q${x} ${y} ${x + 2 * k} ${y}Q${x} ${y} ${x} ${y + 2 * k}Q${x} ${y} ${x - 2 * k} ${y}Q${x} ${y} ${x} ${y - 2 * k}Z`;

function Star({ size, color }: { size: number; color: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flex: "none" }}>
      <path
        fill={color}
        d="M12 1.8c.5 0 .9.3 1.1.8l2.3 5.6 6 .5c1 .1 1.4 1.3.7 2l-4.6 3.9 1.4 5.9c.2 1-.8 1.7-1.7 1.2L12 18.6l-5.2 3.1c-.9.5-1.9-.2-1.7-1.2l1.4-5.9L1.9 10.7c-.7-.7-.3-1.9.7-2l6-.5 2.3-5.6c.2-.5.6-.8 1.1-.8z"
      />
    </svg>
  );
}

function Card() {
  return (
    <div
      style={{
        position: "relative",
        width: W,
        height: H,
        overflow: "hidden",
        color: TEXT,
        background: `radial-gradient(ellipse 900px 360px at 38% 118%, rgba(${SKY.glow},.55), rgba(${SKY.glow},.12) 55%, transparent 75%),
          radial-gradient(ellipse 500px 400px at 82% 20%, rgba(120,110,255,.18), transparent 70%),
          linear-gradient(180deg, ${SKY.top} 0%, ${SKY.mid} 55%, ${SKY.low} 100%)`,
      }}
    >
      <svg width={W} height={H} style={{ position: "absolute", inset: 0 }}>
        {stars(260).map((s, i) => (
          <circle key={i} cx={s.x} cy={s.y} r={s.r} fill={s.warm ? STAR : "#dfe4ff"} opacity={s.o} />
        ))}
        {[[590, 60, 8], [70, 540, 6], [1140, 575, 7], [660, 500, 5]].map(([x, y, k], i) => (
          <path key={i} d={sparkle(x, y, k)} fill="#ffe9b0" />
        ))}
      </svg>
      {/* shooting star */}
      <div
        style={{
          position: "absolute",
          top: 74,
          left: 520,
          width: 190,
          height: 2,
          borderRadius: 2,
          transform: "rotate(-22deg)",
          background: "linear-gradient(90deg, rgba(255,223,138,0), rgba(255,244,214,.95))",
          boxShadow: "0 0 8px rgba(255,223,138,.6)",
        }}
      />

      <div style={{ position: "absolute", left: 72, top: 64, width: 620, display: "flex", flexDirection: "column", gap: 26 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, fontFamily: DISPLAY, fontWeight: 600, fontSize: 34, ...SOFT }}>
          <img src="/app-icon.png" alt="" style={{ width: 58, height: 58, borderRadius: 14, boxShadow: "0 8px 24px -8px rgba(0,0,0,.6)" }} />
          Hoshi <span style={{ fontSize: 26, color: STAR, fontWeight: 500 }}>星</span>
        </div>
        <div style={{ fontFamily: DISPLAY, fontWeight: 600, fontSize: 66, lineHeight: 1.02, letterSpacing: "-0.015em", ...SOFT }}>
          I wrote a wish list.
          <span style={{ display: "block", fontStyle: "italic", fontWeight: 500, color: STAR }}>Then I built the terminal.</span>
        </div>
        <div style={{ fontFamily: "var(--font-inter), sans-serif", fontSize: 25, lineHeight: 1.35, color: MUTED }}>
          SSH &amp; Mosh for iPhone and iPad.
          <br />
          <b style={{ color: "#fff", fontWeight: 600 }}>Open source. $4.99 once.</b>
        </div>
        <div style={{ display: "flex", gap: 10, fontFamily: MONO, fontSize: 17, fontWeight: 500 }}>
          {["mosh", "tmux", "herdr", "your themes"].map((t) => (
            <span key={t} style={{ padding: "7px 14px", borderRadius: 999, border: "1.5px solid rgba(255,223,138,.35)", color: STAR, background: "rgba(255,223,138,.06)" }}>
              {t}
            </span>
          ))}
        </div>
      </div>

      <Phone
        src={shot("joystick")}
        width={300}
        style={{ left: W - 70 - 300, top: 46, transform: "rotate(4deg)", boxShadow: "0 50px 90px -30px rgba(0,0,0,.85), 0 0 120px rgba(255,223,138,.10)" }}
      />

      {/* taped wish list */}
      <div
        style={{
          position: "absolute",
          left: 652,
          top: 300,
          width: 228,
          padding: "14px 14px 14px 28px",
          borderRadius: 3,
          transform: "rotate(-6deg)",
          color: PAPER.ink,
          background: `repeating-linear-gradient(180deg, transparent 0 25px, ${PAPER.rule} 25px 26px) 0 40px, ${PAPER.bg}`,
          boxShadow: "0 30px 44px -16px rgba(0,0,0,.75)",
          fontFamily: HAND,
          fontSize: 15,
          lineHeight: "26px",
        }}
      >
        <div style={{ position: "absolute", top: 0, bottom: 0, left: 18, width: 1.5, background: PAPER.margin, opacity: 0.5 }} />
        <div style={{ position: "absolute", top: -11, left: "50%", width: 80, height: 22, transform: "translateX(-50%) rotate(3deg)", background: "rgba(255,223,138,.7)" }} />
        <div style={{ fontWeight: 700, fontSize: 17 }}>my terminal wishes</div>
        {WISHES.map((w) => (
          <div key={w} style={{ display: "flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
            <Star size={13} color="#e3a520" />
            {w}
          </div>
        ))}
      </div>
    </div>
  );
}

export const SOCIAL_CARDS = [{ id: "og", C: Card }] as const;
