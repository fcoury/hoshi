// Social card for gethoshi.app (og:image / twitter:image), 1200x630.
// Exported by `bun run export -- --social` to ../site/img/og.jpg.
import { BRAND, CANVAS } from "@/lib/brand";
import { Backdrop, Crop, Phone, Pills } from "@/components/kit";

const { w: W, h: H } = CANVAS.social;
const shot = (name: string) => `/shots/iphone/${name}.png`;
const MONO = "var(--font-mono), 'JetBrains Mono', ui-monospace, monospace";

// Live Activity card edges in the lock-screen capture (see iphone.tsx).
const LIVE_ACTIVITY = { x: 42, y: 1918, w: 1122, h: 320 };

function Card() {
  return (
    <Backdrop w={W} h={H} variant="night">
      <div style={{ position: "absolute", left: 72, top: 70, width: 560 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 18, marginBottom: 46 }}>
          <img
            src="/app-icon.png"
            alt=""
            style={{
              width: 64,
              height: 64,
              borderRadius: 15,
              boxShadow: `0 0 40px ${BRAND.accentGlow}, 0 6px 18px rgba(0,0,0,0.5)`,
            }}
          />
          <span style={{ fontSize: 34, fontWeight: 800, color: BRAND.fg, letterSpacing: "-0.01em" }}>
            Hoshi
          </span>
        </div>
        <div style={{ fontFamily: MONO, fontSize: 22, fontWeight: 600, color: BRAND.gold, marginBottom: 18 }}>
          SSH · Mosh · tmux
        </div>
        <div
          style={{
            fontSize: 68,
            fontWeight: 800,
            lineHeight: 1.04,
            letterSpacing: "-0.03em",
            color: BRAND.fg,
          }}
        >
          The terminal for
          <br />
          <span style={{ color: BRAND.accent }}>coding agents.</span>
        </div>
        <div style={{ fontSize: 25, lineHeight: 1.4, color: BRAND.fgMuted, marginTop: 24, width: 500 }}>
          Watch your agents work and reply from the Lock Screen. iPhone and iPad.
        </div>
        <Pills
          center={false}
          size={19}
          items={["No account", "No subscription", "Data Not Collected"]}
          style={{ marginTop: 34 }}
        />
      </div>

      {/* Phone bleeding off the bottom edge, Live Activity overlapping it. */}
      <Phone src={shot("agent-working")} width={360} style={{ left: 760, top: 58 }} />
      <Crop
        src={shot("lock-live-activity")}
        region={LIVE_ACTIVITY}
        width={440}
        radius={30}
        style={{ left: 668, top: 404 }}
      />
    </Backdrop>
  );
}

export const SOCIAL_CARDS = [{ id: "og", C: Card }] as const;
