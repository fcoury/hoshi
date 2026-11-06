// iPad 13" slides, portrait, designed at 2064x2752 (native capture size).
import type { ReactNode } from "react";
import { BRAND, CANVAS, CAPTURE } from "@/lib/brand";
import { Backdrop, Caption, Crop, Pills, Tablet } from "@/components/kit";

const { w: W, h: H } = CANVAS.ipad;
const shot = (name: string) => `/shots/ipad/${name}.png`;

const HEAD = 124;
const TAB_W = 1780;
const TAB_LEFT = (W - TAB_W) / 2;
const TAB_TOP = 720;

function Standard({
  kicker,
  line1,
  line2,
  src,
  variant = "night",
  children,
}: {
  kicker: string;
  line1: ReactNode;
  line2: ReactNode;
  src: string;
  variant?: "night" | "deep";
  children?: ReactNode;
}) {
  return (
    <Backdrop w={W} h={H} variant={variant}>
      <Caption
        kicker={kicker}
        line1={line1}
        line2={line2}
        size={HEAD}
        style={{ position: "absolute", top: 170, left: 0, right: 0 }}
      />
      <Tablet src={src} width={TAB_W} style={{ left: TAB_LEFT, top: TAB_TOP }} />
      {children}
    </Backdrop>
  );
}

const R = {
  liveActivity: { x: 0, y: 0, w: 1, h: 1 }, // set after the iPad capture
};

function Hero() {
  return (
    <Standard
      kicker="SSH · Mosh · tmux"
      line1="The terminal"
      line2="for coding agents."
      src={shot("split-agent")}
    >
      <Pills
        items={["No account", "No paywalls", "Data Not Collected"]}
        size={44}
        style={{ position: "absolute", top: 560, left: 0, right: 0 }}
      />
    </Standard>
  );
}

function Agents() {
  return (
    <Standard
      kicker="Agents"
      line1="Your agents at a glance."
      line2="Reply in one tap."
      src={shot("reply")}
    />
  );
}

function BigTerminal() {
  return (
    <Standard
      kicker="Terminal"
      line1="A real terminal,"
      line2="built for the big screen."
      src={shot("vim")}
      variant="deep"
    />
  );
}

function Files() {
  return (
    <Standard kicker="Files" line1="Browse and upload" line2="over SFTP." src={shot("sftp")} />
  );
}

function Sessions() {
  return (
    <Standard
      kicker="Multi-session"
      line1="Every server,"
      line2="side by side."
      src={shot("sessions")}
      variant="deep"
    />
  );
}

function Closer() {
  return (
    <Backdrop w={W} h={H} variant="accent">
      <img
        src="/app-icon.png"
        alt=""
        style={{
          position: "absolute",
          left: (W - 440) / 2,
          top: 500,
          width: 440,
          height: 440,
          borderRadius: 100,
          boxShadow: "0 40px 120px rgba(0,0,0,0.45)",
        }}
      />
      <Caption
        kicker="Private by design"
        line1="Your servers."
        line2="Your keys."
        size={150}
        tone="light"
        style={{ position: "absolute", top: 1090, left: 0, right: 0 }}
      />
      <div
        style={{
          position: "absolute",
          top: 1640,
          left: 0,
          right: 0,
          textAlign: "center",
          fontSize: 56,
          fontWeight: 600,
          color: "rgba(255,255,255,0.88)",
        }}
      >
        No account · no ads · no tracking
      </div>
      <Pills
        tone="light"
        size={52}
        items={[
          "Mosh", "tmux", "Herdr", "Live Activities", "SFTP", "Voice",
          "50+ Nerd Fonts", "Known Hosts", "Face ID lock", "iPhone",
          "Family Sharing",
        ]}
        style={{ position: "absolute", top: 1880, left: 200, right: 200 }}
      />
    </Backdrop>
  );
}

// Keep imports used even before the iPad crops are tuned.
void Crop; void BRAND; void CAPTURE; void R;

export const IPAD_SLIDES = [
  { id: "hero", C: Hero },
  { id: "agents", C: Agents },
  { id: "terminal", C: BigTerminal },
  { id: "sftp", C: Files },
  { id: "sessions", C: Sessions },
  { id: "private", C: Closer },
] as const;
