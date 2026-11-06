// App Preview title cards, 886x1920, set in JetBrains Mono. Exported by
// `bun run export -- --cards` and cut into the video by
// scripts/screenshots/compose-preview.mjs.
import type { ReactNode } from "react";
import { BRAND, CANVAS } from "@/lib/brand";
import { Backdrop } from "@/components/kit";

const { w: W, h: H } = CANVAS.preview;
const MONO = "var(--font-mono), 'JetBrains Mono', ui-monospace, monospace";

function Card({
  comment,
  lines,
  icon = false,
  variant = "night",
  footer,
}: {
  comment: string;
  lines: ReactNode[];
  icon?: boolean;
  variant?: "night" | "deep" | "accent";
  footer?: ReactNode;
}) {
  const light = variant === "accent";
  return (
    <Backdrop w={W} h={H} variant={variant}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "0 76px",
          fontFamily: MONO,
        }}
      >
        {icon && (
          <img
            src="/app-icon.png"
            alt=""
            style={{
              width: 168,
              height: 168,
              borderRadius: 38,
              marginBottom: 72,
              boxShadow: light
                ? "0 30px 90px rgba(0,0,0,0.4)"
                : `0 0 80px ${BRAND.accentGlow}, 0 12px 40px rgba(0,0,0,0.5)`,
            }}
          />
        )}
        <div
          style={{
            fontSize: 34,
            fontWeight: 500,
            color: light ? "rgba(255,255,255,0.78)" : BRAND.gold,
            marginBottom: 34,
          }}
        >
          {comment}
        </div>
        {lines.map((line, i) => (
          <div
            key={i}
            style={{
              fontSize: 66,
              fontWeight: 800,
              lineHeight: 1.18,
              letterSpacing: "-0.02em",
              color: light ? "#fff" : i === 0 ? BRAND.fg : BRAND.fgMuted,
            }}
          >
            {line}
          </div>
        ))}
        {footer && <div style={{ marginTop: 64 }}>{footer}</div>}
      </div>
    </Backdrop>
  );
}

/** A `❯` prompt, the cards' recurring motif. */
const Prompt = ({ children, light }: { children: ReactNode; light?: boolean }) => (
  <span>
    <span style={{ color: light ? "#fff" : BRAND.accent }}>❯ </span>
    {children}
  </span>
);

function Intro() {
  return (
    <Card
      icon
      comment="# hoshi"
      lines={[<Prompt key="a">The open-source</Prompt>, "terminal for", "coding agents."]}
    />
  );
}

function Agents() {
  return (
    <Card
      comment="# agents"
      variant="deep"
      lines={[<Prompt key="a">Your agents</Prompt>, "ping you.", "Reply from the", "Lock Screen."]}
    />
  );
}

function Terminal() {
  return (
    <Card
      comment="# terminal"
      variant="deep"
      lines={[<Prompt key="a">A real terminal.</Prompt>, "tmux, vim,", "over Mosh."]}
    />
  );
}

function Outro() {
  return (
    <Card
      icon
      variant="accent"
      comment="# open source · MIT"
      lines={[<Prompt key="a" light>Open source.</Prompt>, "Nothing to", "unlock."]}
      footer={
        <div style={{ fontSize: 32, fontWeight: 500, color: "rgba(255,255,255,0.85)", lineHeight: 1.6 }}>
          github.com/fcoury/hoshi
          <br />
          no account · no ads · no tracking
        </div>
      }
    />
  );
}

export const PREVIEW_CARDS = [
  { id: "intro", C: Intro },
  { id: "agents", C: Agents },
  { id: "terminal", C: Terminal },
  { id: "outro", C: Outro },
] as const;
