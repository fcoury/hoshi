// iPhone slides, designed at 1320x2868. Captures come from
// scripts/screenshots/capture.sh (iPhone 17 Pro, 1206x2622) and are copied to
// public/shots/iphone/ by scripts/screenshots/sync.sh.
import type { ReactNode } from "react";
import { BRAND, CANVAS } from "@/lib/brand";
import { Backdrop, Caption, Crop, Phone, Pills, Touch } from "@/components/kit";

const { w: W, h: H } = CANVAS.iphone;
const shot = (name: string) => `/shots/iphone/${name}.png`;

// Shared geometry: caption at the top, phone below bleeding off the bottom.
const HEAD = 104;              // headline font size
const CAPTION_TOP = 150;
const PHONE_W = 1010;
const PHONE_TOP = 760;
const PHONE_LEFT = (W - PHONE_W) / 2;
// Screen scale inside the frame: canvas px per capture px.
const SCREEN_SCALE = (PHONE_W - PHONE_W * 0.028 * 2) / 1206;

/** Position of a capture-pixel point on the canvas for the standard phone. */
const onPhone = (x: number, y: number) => ({
  x: PHONE_LEFT + PHONE_W * 0.028 + x * SCREEN_SCALE,
  y: PHONE_TOP + PHONE_W * 0.028 + y * SCREEN_SCALE,
});

function Standard({
  kicker,
  line1,
  line2,
  src,
  variant = "night",
  children,
  phoneTop = PHONE_TOP,
}: {
  kicker: string;
  line1: ReactNode;
  line2: ReactNode;
  src: string;
  variant?: "night" | "deep";
  children?: ReactNode;
  phoneTop?: number;
}) {
  return (
    <Backdrop w={W} h={H} variant={variant}>
      <Caption
        kicker={kicker}
        line1={line1}
        line2={line2}
        size={HEAD}
        style={{ position: "absolute", top: CAPTION_TOP, left: 0, right: 0 }}
      />
      <Phone src={src} width={PHONE_W} style={{ left: PHONE_LEFT, top: phoneTop }} />
      {children}
    </Backdrop>
  );
}

// Regions in capture pixels (1206x2622).
const R = {
  liveActivity: { x: 42, y: 1918, w: 1122, h: 320 }, // measured: card edges
  replyComposer: { x: 24, y: 1256, w: 1158, h: 1343 }, // floating sheet edges
  uploadSheet: { x: 24, y: 1259, w: 1158, h: 1340 },
  header: { x: 0, y: 200, w: 1206, h: 120 },
};

// ─── 1. Hero ───────────────────────────────────────────────────────────────
function Hero() {
  return (
    <Backdrop w={W} h={H}>
      <img
        src="/app-icon.png"
        alt=""
        style={{
          position: "absolute",
          left: (W - 168) / 2,
          top: 120,
          width: 168,
          height: 168,
          borderRadius: 38,
          boxShadow: `0 0 80px ${BRAND.accentGlow}, 0 12px 40px rgba(0,0,0,0.5)`,
        }}
      />
      <Caption
        kicker="SSH · Mosh · tmux"
        line1="The terminal"
        line2="for coding agents."
        size={92}
        style={{ position: "absolute", top: 340, left: 0, right: 0 }}
      />
      <Pills
        items={["No account", "No paywalls", "Data Not Collected"]}
        size={34}
        style={{ position: "absolute", top: 700, left: 60, right: 60 }}
      />
      <Phone src={shot("agent-working")} width={940} style={{ left: (W - 940) / 2, top: 860 }} />
      <Crop
        src={shot("lock-live-activity")}
        region={R.liveActivity}
        width={1180}
        radius={76}
        style={{ left: (W - 1180) / 2, top: 2330 }}
      />
    </Backdrop>
  );
}

// ─── 2. Lock Screen reply ──────────────────────────────────────────────────
function LockScreen() {
  return (
    <Standard
      kicker="Agents"
      line1="Answer your agents"
      line2="from the Lock Screen."
      src={shot("lock-live-activity")}
    >
      <Crop
        src={shot("reply-typed")}
        region={R.replyComposer}
        width={1080}
        radius={(110 * 1080) / 1158}
        style={{ left: (W - 1080) / 2, top: 1700 }}
      />
    </Standard>
  );
}

// ─── 3. Sessions picker ────────────────────────────────────────────────────
function Picker() {
  return (
    <Standard
      kicker="tmux + Herdr"
      line1="Every session,"
      line2="one tap away."
      src={shot("picker")}
    >
      <Pills
        items={["Auto-detected", "Nothing to install"]}
        size={36}
        style={{ position: "absolute", top: 620, left: 0, right: 0 }}
      />
    </Standard>
  );
}

// ─── 4. Mosh ───────────────────────────────────────────────────────────────
function Mosh() {
  return (
    <Standard
      kicker="Mosh"
      line1="Wi-Fi to 5G."
      line2="Session still there."
      src={shot("tmux-git")}
    >
      <Pills
        items={["Native Mosh", "Roams networks", "Survives sleep"]}
        size={36}
        style={{ position: "absolute", top: 620, left: 0, right: 0 }}
      />
    </Standard>
  );
}

// ─── 5. Joystick ───────────────────────────────────────────────────────────
function Joystick() {
  const finger = onPhone(600, 1260);
  return (
    <Standard
      kicker="Keyboard"
      line1="Hold anywhere"
      line2="for arrow keys."
      src={shot("joystick")}
    >
      <Touch x={finger.x + 60} y={finger.y} size={120} />
    </Standard>
  );
}

// ─── 6. Voice ──────────────────────────────────────────────────────────────
function Voice() {
  return (
    <Standard
      kicker="Voice"
      line1="Speak your prompt."
      line2="Transcribed on device."
      src={shot("voice")}
      variant="deep"
    />
  );
}

// ─── 7. Selection ──────────────────────────────────────────────────────────
function Selection() {
  return (
    <Standard
      kicker="Touch"
      line1="Select, copy, paste."
      line2="It just works."
      src={shot("selection")}
    />
  );
}

// ─── 8. SFTP ───────────────────────────────────────────────────────────────
function Sftp() {
  return (
    <Standard
      kicker="Files"
      line1="Browse and upload"
      line2="over SFTP."
      src={shot("sftp-home")}
    >
      <Crop
        src={shot("upload")}
        region={R.uploadSheet}
        width={1000}
        radius={(110 * 1000) / 1158}
        style={{ left: (W - 1000) / 2 + 40, top: 1900 }}
      />
    </Standard>
  );
}

// ─── 9. Sessions ───────────────────────────────────────────────────────────
function Sessions() {
  return (
    <Standard
      kicker="Multi-session"
      line1="Every server,"
      line2="every session."
      src={shot("sessions-sheet")}
      variant="deep"
    />
  );
}

// ─── 10. Closer ────────────────────────────────────────────────────────────
function Closer() {
  return (
    <Backdrop w={W} h={H} variant="accent">
      <img
        src="/app-icon.png"
        alt=""
        style={{
          position: "absolute",
          left: (W - 360) / 2,
          top: 420,
          width: 360,
          height: 360,
          borderRadius: 82,
          boxShadow: "0 40px 120px rgba(0,0,0,0.45)",
        }}
      />
      <Caption
        kicker="Private by design"
        line1="Your servers."
        line2="Your keys."
        size={118}
        tone="light"
        style={{ position: "absolute", top: 940, left: 0, right: 0 }}
      />
      <div
        style={{
          position: "absolute",
          top: 1400,
          left: 0,
          right: 0,
          textAlign: "center",
          fontSize: 44,
          fontWeight: 600,
          color: "rgba(255,255,255,0.88)",
        }}
      >
        No account · no ads · no tracking
      </div>
      <Pills
        tone="light"
        size={42}
        items={[
          "Mosh", "tmux", "Herdr", "Live Activities", "SFTP", "Voice",
          "50+ Nerd Fonts", "Known Hosts", "Face ID lock", "iPad",
          "Family Sharing",
        ]}
        style={{ position: "absolute", top: 1620, left: 110, right: 110 }}
      />
    </Backdrop>
  );
}

export const IPHONE_SLIDES = [
  { id: "hero", C: Hero },
  { id: "lock-screen", C: LockScreen },
  { id: "sessions-picker", C: Picker },
  { id: "mosh", C: Mosh },
  { id: "joystick", C: Joystick },
  { id: "voice", C: Voice },
  { id: "selection", C: Selection },
  { id: "sftp", C: Sftp },
  { id: "multi-session", C: Sessions },
  { id: "private", C: Closer },
] as const;
