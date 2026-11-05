// Building blocks for slides: device frames, captions, crops of real captures,
// backgrounds and pills. Everything is sized in canvas pixels so exports are
// exact; slides compose these with absolute positioning.
import type { CSSProperties, ReactNode } from "react";
import { BRAND, CAPTURE } from "@/lib/brand";

// ─── Backdrop ──────────────────────────────────────────────────────────────

export function Backdrop({
  w,
  h,
  variant = "night",
  children,
}: {
  w: number;
  h: number;
  variant?: "night" | "deep" | "accent";
  children: ReactNode;
}) {
  const backgrounds = {
    night: `radial-gradient(120% 60% at 15% 0%, rgba(56,120,255,0.20) 0%, transparent 60%),
            radial-gradient(80% 40% at 100% 10%, rgba(232,198,107,0.10) 0%, transparent 60%),
            linear-gradient(180deg, ${BRAND.bgTop} 0%, ${BRAND.bg} 55%)`,
    deep: `radial-gradient(90% 50% at 50% 0%, rgba(56,120,255,0.16) 0%, transparent 65%),
           linear-gradient(180deg, #0a0f1c 0%, ${BRAND.bg} 60%)`,
    accent: `radial-gradient(100% 60% at 50% 0%, rgba(255,255,255,0.22) 0%, transparent 60%),
             linear-gradient(170deg, #4a86ff 0%, #2a5fe0 55%, #1d46b8 100%)`,
  } as const;
  return (
    <div
      style={{
        width: w,
        height: h,
        position: "relative",
        overflow: "hidden",
        background: backgrounds[variant],
        fontFamily: "var(--font-inter), Inter, -apple-system, sans-serif",
        color: BRAND.fg,
      }}
    >
      <Stars w={w} h={h} faint={variant === "accent"} />
      {children}
    </div>
  );
}

// Sparse gold dots, a nod to "hoshi" (star). Deterministic positions.
function Stars({ w, h, faint }: { w: number; h: number; faint?: boolean }) {
  const dots = [
    [0.08, 0.05, 4], [0.22, 0.11, 3], [0.71, 0.04, 5], [0.88, 0.13, 3],
    [0.93, 0.32, 4], [0.05, 0.36, 3], [0.62, 0.17, 2], [0.4, 0.03, 3],
  ];
  return (
    <>
      {dots.map(([x, y, s], i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: x * w,
            top: y * h,
            width: s * (w / 1320),
            height: s * (w / 1320),
            borderRadius: "50%",
            background: faint ? "#fff" : BRAND.gold,
            opacity: faint ? 0.35 : 0.55,
          }}
        />
      ))}
    </>
  );
}

// ─── Caption ───────────────────────────────────────────────────────────────

export function Caption({
  kicker,
  line1,
  line2,
  size,
  align = "center",
  tone = "dark",
  style,
}: {
  kicker: string;
  line1: ReactNode;
  line2?: ReactNode;
  size: number; // headline font size in px
  align?: "center" | "left";
  tone?: "dark" | "light";
  style?: CSSProperties;
}) {
  const onAccent = tone === "light";
  return (
    <div style={{ textAlign: align, ...style }}>
      <div
        style={{
          display: "inline-block",
          fontSize: size * 0.3,
          fontWeight: 700,
          letterSpacing: "0.14em",
          textTransform: "uppercase",
          color: onAccent ? "rgba(255,255,255,0.85)" : BRAND.gold,
          marginBottom: size * 0.32,
        }}
      >
        {kicker}
      </div>
      <div
        style={{
          fontSize: size,
          fontWeight: 800,
          lineHeight: 1.04,
          letterSpacing: "-0.025em",
          color: onAccent ? "#fff" : BRAND.fg,
        }}
      >
        {line1}
      </div>
      {line2 && (
        <div
          style={{
            fontSize: size,
            fontWeight: 800,
            lineHeight: 1.04,
            letterSpacing: "-0.025em",
            color: onAccent ? "rgba(255,255,255,0.72)" : BRAND.fgMuted,
          }}
        >
          {line2}
        </div>
      )}
    </div>
  );
}

// ─── Device frames ─────────────────────────────────────────────────────────

/** iPhone 17 Pro-style frame drawn in CSS around a native capture.
 *  `width` is the outer frame width in canvas px. */
export function Phone({
  src,
  width,
  style,
  island = true,
  children,
}: {
  src: string;
  width: number;
  style?: CSSProperties;
  island?: boolean;
  children?: ReactNode; // overlays positioned in screen coordinates (0..1)
}) {
  const bezel = width * 0.028;
  const screenW = width - bezel * 2;
  const screenH = screenW * (CAPTURE.iphone.h / CAPTURE.iphone.w);
  const radius = screenW * 0.137;
  return (
    <div
      style={{
        position: "absolute",
        width,
        height: screenH + bezel * 2,
        borderRadius: radius + bezel,
        padding: bezel,
        background: "linear-gradient(145deg, #3a3f4a 0%, #1b1e25 35%, #2b2f38 70%, #14161b 100%)",
        boxShadow: `0 ${width * 0.05}px ${width * 0.12}px rgba(0,0,0,0.55),
                    0 0 0 ${width * 0.003}px rgba(255,255,255,0.08) inset`,
        ...style,
      }}
    >
      <div
        style={{
          position: "relative",
          width: screenW,
          height: screenH,
          borderRadius: radius,
          overflow: "hidden",
          background: "#000",
        }}
      >
        <img
          src={src}
          alt=""
          style={{ display: "block", width: "100%", height: "100%", objectFit: "cover" }}
        />
        {island && (
          <div
            style={{
              position: "absolute",
              top: screenH * 0.0128,
              left: "50%",
              transform: "translateX(-50%)",
              width: screenW * 0.31,
              height: screenH * 0.042,
              borderRadius: screenH,
              background: "#000",
            }}
          />
        )}
        {children}
      </div>
    </div>
  );
}

/** iPad Pro 13" portrait frame. `width` is the outer width. */
export function Tablet({
  src,
  width,
  style,
  children,
}: {
  src: string;
  width: number;
  style?: CSSProperties;
  children?: ReactNode;
}) {
  const bezel = width * 0.018;
  const screenW = width - bezel * 2;
  const screenH = screenW * (CAPTURE.ipad.h / CAPTURE.ipad.w);
  const radius = screenW * 0.024;
  return (
    <div
      style={{
        position: "absolute",
        width,
        height: screenH + bezel * 2,
        borderRadius: radius + bezel,
        padding: bezel,
        background: "linear-gradient(145deg, #3a3f4a 0%, #1b1e25 40%, #2b2f38 75%, #14161b 100%)",
        boxShadow: `0 ${width * 0.03}px ${width * 0.08}px rgba(0,0,0,0.55)`,
        ...style,
      }}
    >
      <div
        style={{
          position: "relative",
          width: screenW,
          height: screenH,
          borderRadius: radius,
          overflow: "hidden",
          background: "#000",
        }}
      >
        <img src={src} alt="" style={{ display: "block", width: "100%", height: "100%" }} />
        {children}
      </div>
    </div>
  );
}

// ─── Crop: a region of a real capture, shown as a floating card ────────────

/** Shows the region (x, y, w, h) of a capture, in capture pixels, scaled to
 *  `width` canvas px. Used for callouts like the Live Activity card. */
export function Crop({
  src,
  region,
  capture = CAPTURE.iphone,
  width,
  radius = 0,
  style,
  shadow = true,
}: {
  src: string;
  region: { x: number; y: number; w: number; h: number };
  capture?: { w: number; h: number };
  width: number;
  radius?: number;
  style?: CSSProperties;
  shadow?: boolean;
}) {
  const scale = width / region.w;
  return (
    <div
      style={{
        position: "absolute",
        width,
        height: region.h * scale,
        borderRadius: radius,
        overflow: "hidden",
        boxShadow: shadow ? `0 ${width * 0.04}px ${width * 0.1}px rgba(0,0,0,0.6)` : undefined,
        ...style,
      }}
    >
      <img
        src={src}
        alt=""
        style={{
          position: "absolute",
          width: capture.w * scale,
          height: capture.h * scale,
          left: -region.x * scale,
          top: -region.y * scale,
          maxWidth: "none",
        }}
      />
    </div>
  );
}

// ─── Pills and touch hotspot ───────────────────────────────────────────────

export function Pills({
  items,
  size,
  tone = "dark",
  style,
  center = true,
}: {
  items: string[];
  size: number;
  tone?: "dark" | "light";
  style?: CSSProperties;
  center?: boolean;
}) {
  const light = tone === "light";
  return (
    <div
      style={{
        display: "flex",
        flexWrap: "wrap",
        gap: size * 0.45,
        justifyContent: center ? "center" : "flex-start",
        ...style,
      }}
    >
      {items.map((t) => (
        <div
          key={t}
          style={{
            fontSize: size,
            fontWeight: 600,
            padding: `${size * 0.42}px ${size * 0.85}px`,
            borderRadius: size * 2,
            color: light ? "#fff" : BRAND.fg,
            background: light ? "rgba(255,255,255,0.16)" : "rgba(255,255,255,0.06)",
            border: `${Math.max(2, size * 0.06)}px solid ${light ? "rgba(255,255,255,0.28)" : "rgba(255,255,255,0.10)"}`,
            whiteSpace: "nowrap",
          }}
        >
          {t}
        </div>
      ))}
    </div>
  );
}

/** A soft touch indicator (Apple allows touch hotspots in screenshots). */
export function Touch({ x, y, size }: { x: number; y: number; size: number }) {
  return (
    <div
      style={{
        position: "absolute",
        left: x - size / 2,
        top: y - size / 2,
        width: size,
        height: size,
        borderRadius: "50%",
        background: "rgba(255,255,255,0.28)",
        border: `${size * 0.05}px solid rgba(255,255,255,0.75)`,
        boxShadow: "0 0 40px rgba(255,255,255,0.35)",
      }}
    />
  );
}
