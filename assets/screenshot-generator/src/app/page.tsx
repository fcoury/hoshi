"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { toPng } from "html-to-image";

// ─── Design at largest Apple-required size, scale down for export ───
const IPHONE_W = 1320;
const IPHONE_H = 2868;

const IPHONE_SIZES = [
  { label: '6.9"', w: 1320, h: 2868 },
  { label: '6.5"', w: 1284, h: 2778 },
  { label: '6.3"', w: 1206, h: 2622 },
  { label: '6.1"', w: 1125, h: 2436 },
] as const;

// ─── Brand tokens ───
const BRAND = {
  bg: "#08090d",
  bgAlt: "#0f1118",
  fg: "#e8eaf0",
  fgMuted: "#8b8fa3",
  accent: "#3878ff",
  accentGlow: "rgba(56, 120, 255, 0.35)",
  green: "#50c878",
  gold: "#C9A96E",
  goldGlow: "rgba(201, 169, 110, 0.3)",
};

// ─── Phone mockup measurements ───
const MK_W = 1022;
const MK_H = 2082;
const SC_L = (52 / MK_W) * 100;
const SC_T = (46 / MK_H) * 100;
const SC_W = (918 / MK_W) * 100;
const SC_H = (1990 / MK_H) * 100;
const SC_RX = (126 / 918) * 100;
const SC_RY = (126 / 1990) * 100;

// ─── Phone component ───
function Phone({
  src,
  alt,
  style,
  className = "",
}: {
  src: string;
  alt: string;
  style?: React.CSSProperties;
  className?: string;
}) {
  return (
    <div
      className={`relative ${className}`}
      style={{ aspectRatio: `${MK_W}/${MK_H}`, ...style }}
    >
      <img
        src="/mockup.png"
        alt=""
        className="block w-full h-full"
        draggable={false}
      />
      <div
        className="absolute z-10 overflow-hidden"
        style={{
          left: `${SC_L}%`,
          top: `${SC_T}%`,
          width: `${SC_W}%`,
          height: `${SC_H}%`,
          borderRadius: `${SC_RX}% / ${SC_RY}%`,
        }}
      >
        <img
          src={src}
          alt={alt}
          className="block w-full h-full object-cover object-top"
          draggable={false}
        />
      </div>
    </div>
  );
}

// ─── Caption component ───
function Caption({
  label,
  headline,
  canvasW = IPHONE_W,
  color = BRAND.fg,
  labelColor,
  align = "center",
  style,
}: {
  label: string;
  headline: React.ReactNode;
  canvasW?: number;
  color?: string;
  labelColor?: string;
  align?: "center" | "left" | "right";
  style?: React.CSSProperties;
}) {
  return (
    <div style={{ textAlign: align, ...style }}>
      <div
        style={{
          fontSize: canvasW * 0.028,
          fontWeight: 600,
          color: labelColor || BRAND.accent,
          textTransform: "uppercase",
          letterSpacing: "0.12em",
          marginBottom: canvasW * 0.02,
        }}
      >
        {label}
      </div>
      <div
        style={{
          fontSize: canvasW * 0.09,
          fontWeight: 700,
          color,
          lineHeight: 1.0,
        }}
      >
        {headline}
      </div>
    </div>
  );
}

// ─── Decorative: Glow blob ───
function GlowBlob({
  color,
  size,
  top,
  left,
  right,
  bottom,
  opacity = 0.4,
}: {
  color: string;
  size: number;
  top?: string;
  left?: string;
  right?: string;
  bottom?: string;
  opacity?: number;
}) {
  return (
    <div
      style={{
        position: "absolute",
        width: size,
        height: size,
        borderRadius: "50%",
        background: `radial-gradient(circle, ${color} 0%, transparent 70%)`,
        top,
        left,
        right,
        bottom,
        opacity,
        filter: `blur(${size * 0.3}px)`,
        pointerEvents: "none",
      }}
    />
  );
}

// ─── Slide 1: Hero ───
function Slide1() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(165deg, #0d1220 0%, ${BRAND.bg} 40%, #0a0f1a 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
      }}
    >
      {/* Background glow */}
      <GlowBlob color={BRAND.accent} size={800} top="-10%" left="-20%" opacity={0.15} />
      <GlowBlob color={BRAND.gold} size={500} top="5%" right="-15%" opacity={0.1} />

      {/* App icon */}
      <img
        src="/app-icon.png"
        alt="Hoshi"
        style={{
          width: 140,
          height: 140,
          borderRadius: 32,
          marginTop: IPHONE_H * 0.06,
          boxShadow: `0 0 60px ${BRAND.accentGlow}, 0 8px 32px rgba(0,0,0,0.5)`,
        }}
      />

      {/* Caption */}
      <div style={{ marginTop: IPHONE_H * 0.03, zIndex: 2 }}>
        <Caption
          label="Mobile Terminal"
          headline={
            <>
              Your AI agents,
              <br />
              in your pocket.
            </>
          }
        />
      </div>

      {/* Phone — centered, bleeding off bottom */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          left: "50%",
          transform: "translateX(-50%) translateY(12%)",
          width: "82%",
          zIndex: 1,
        }}
      >
        <Phone src="/screenshots/server-list.png" alt="Server list" />
      </div>

      {/* Subtle star dots */}
      {[
        { x: "12%", y: "15%", s: 3 },
        { x: "85%", y: "20%", s: 2 },
        { x: "70%", y: "8%", s: 4 },
        { x: "25%", y: "5%", s: 2 },
        { x: "92%", y: "35%", s: 3 },
      ].map((dot, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: dot.x,
            top: dot.y,
            width: dot.s,
            height: dot.s,
            borderRadius: "50%",
            background: BRAND.gold,
            opacity: 0.5,
          }}
        />
      ))}
    </div>
  );
}

// ─── Slide 2: Terminal Power ───
function Slide2() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(180deg, #0c1022 0%, ${BRAND.bg} 50%, #060810 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
      }}
    >
      {/* Background accent */}
      <GlowBlob color={BRAND.green} size={700} bottom="20%" right="-25%" opacity={0.12} />
      <GlowBlob color={BRAND.accent} size={500} top="10%" left="-15%" opacity={0.08} />

      {/* Caption — left aligned */}
      <div style={{ padding: `${IPHONE_H * 0.08}px ${IPHONE_W * 0.08}px 0`, zIndex: 2 }}>
        <Caption
          label="Ghostty-Powered"
          headline={
            <>
              A real terminal.
              <br />
              Finally.
            </>
          }
          align="left"
          labelColor={BRAND.green}
        />
      </div>

      {/* Phone — offset right */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          right: "-4%",
          transform: "translateY(10%)",
          width: "86%",
          zIndex: 1,
        }}
      >
        <Phone src="/screenshots/terminal.png" alt="Terminal session" />
      </div>
    </div>
  );
}

// ─── Slide 3: Multi-Session ───
function Slide3() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(200deg, #111827 0%, ${BRAND.bg} 50%, #0a0c14 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
      }}
    >
      {/* Background */}
      <GlowBlob color={BRAND.accent} size={900} top="30%" left="20%" opacity={0.1} />

      {/* Caption */}
      <div
        style={{
          padding: `${IPHONE_H * 0.08}px ${IPHONE_W * 0.08}px 0`,
          zIndex: 2,
        }}
      >
        <Caption
          label="Multi-Session"
          headline={
            <>
              Every server,
              <br />
              one swipe.
            </>
          }
          align="left"
        />
      </div>

      {/* Two phones layered */}
      {/* Back phone */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          left: "-8%",
          width: "65%",
          transform: "translateY(14%) rotate(-4deg)",
          opacity: 0.5,
          zIndex: 0,
          filter: "blur(1px)",
        }}
      >
        <Phone src="/screenshots/server-list-2.png" alt="Server list alt" />
      </div>

      {/* Front phone */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          right: "-4%",
          width: "82%",
          transform: "translateY(10%)",
          zIndex: 1,
        }}
      >
        <Phone src="/screenshots/server-list.png" alt="Server list" />
      </div>
    </div>
  );
}

// ─── Slide 4: Resilient Connection ───
function Slide4() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(160deg, #0f1628 0%, #090c16 40%, ${BRAND.bg} 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
      }}
    >
      {/* Background glows */}
      <GlowBlob color={BRAND.gold} size={600} top="15%" left="-10%" opacity={0.12} />
      <GlowBlob color={BRAND.accent} size={400} bottom="30%" right="-10%" opacity={0.1} />

      {/* Caption — right aligned */}
      <div
        style={{
          padding: `${IPHONE_H * 0.08}px ${IPHONE_W * 0.08}px 0`,
          zIndex: 2,
          textAlign: "right",
        }}
      >
        <Caption
          label="Mosh Protocol"
          headline={
            <>
              Never lose
              <br />
              your session.
            </>
          }
          align="right"
          labelColor={BRAND.gold}
        />
      </div>

      {/* Phone — offset left */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          left: "-4%",
          transform: "translateY(10%)",
          width: "86%",
          zIndex: 1,
        }}
      >
        <Phone src="/screenshots/terminal.png" alt="Terminal with Mosh" />
      </div>

      {/* Connection line decoration */}
      <svg
        style={{
          position: "absolute",
          top: "25%",
          right: "5%",
          width: 200,
          height: 300,
          opacity: 0.15,
          zIndex: 0,
        }}
        viewBox="0 0 200 300"
      >
        <path
          d="M 10 10 Q 100 80 80 150 T 180 280"
          stroke={BRAND.gold}
          strokeWidth="2"
          fill="none"
        />
        <circle cx="10" cy="10" r="4" fill={BRAND.gold} />
        <circle cx="80" cy="150" r="3" fill={BRAND.gold} opacity="0.6" />
        <circle cx="180" cy="280" r="4" fill={BRAND.gold} />
      </svg>
    </div>
  );
}

// ─── Slide 5: Identity / Craft ───
function Slide5() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(180deg, #060810 0%, #0a0d16 40%, #08090d 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      {/* Deep warm glow behind kanji */}
      <GlowBlob color={BRAND.gold} size={700} top="25%" left="20%" opacity={0.15} />
      <GlowBlob color={BRAND.accent} size={500} bottom="20%" right="10%" opacity={0.08} />

      {/* Caption */}
      <div style={{ zIndex: 2, marginBottom: IPHONE_H * 0.05 }}>
        <Caption
          label="Hoshi 星"
          headline={
            <>
              Made for devs
              <br />
              who ship
              <br />
              with agents.
            </>
          }
          labelColor={BRAND.gold}
        />
      </div>

      {/* Phone — centered, showing splash */}
      <div
        style={{
          width: "70%",
          zIndex: 1,
          transform: "translateY(8%)",
        }}
      >
        <Phone src="/screenshots/splash.png" alt="Hoshi splash" />
      </div>
    </div>
  );
}

// ─── Slide 6: More Features ───
function Slide6() {
  const features = [
    "SSH & Mosh",
    "tmux Integration",
    "50+ Nerd Fonts",
    "256-Color Terminal",
    "Pinch to Zoom",
    "Swipe Arrows",
    "Sticky Modifiers",
    "Dark Themes",
    "Live Thumbnails",
    "Quick Launch",
    "Touch Selection",
    "Haptic Feedback",
  ];

  const comingSoon = ["iPad Support", "Snippets", "Port Forwarding"];

  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        background: `linear-gradient(180deg, #0c1022 0%, ${BRAND.bg} 50%, #060810 100%)`,
        position: "relative",
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
      }}
    >
      <GlowBlob color={BRAND.accent} size={800} top="10%" left="10%" opacity={0.08} />
      <GlowBlob color={BRAND.gold} size={500} bottom="15%" right="5%" opacity={0.06} />

      {/* App icon */}
      <img
        src="/app-icon.png"
        alt="Hoshi"
        style={{
          width: 120,
          height: 120,
          borderRadius: 28,
          marginTop: IPHONE_H * 0.08,
          boxShadow: `0 0 40px ${BRAND.accentGlow}`,
        }}
      />

      {/* Caption */}
      <div style={{ marginTop: IPHONE_H * 0.03, zIndex: 2 }}>
        <Caption
          label="And there's more"
          headline={
            <>
              Everything you need.
              <br />
              Nothing you don{"'"}t.
            </>
          }
        />
      </div>

      {/* Feature pills */}
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          justifyContent: "center",
          gap: 16,
          padding: `${IPHONE_H * 0.04}px ${IPHONE_W * 0.06}px 0`,
          zIndex: 2,
          maxWidth: "95%",
        }}
      >
        {features.map((f) => (
          <div
            key={f}
            style={{
              padding: "18px 36px",
              borderRadius: 100,
              background: "rgba(255,255,255,0.06)",
              border: "1px solid rgba(255,255,255,0.1)",
              color: BRAND.fg,
              fontSize: IPHONE_W * 0.032,
              fontWeight: 500,
              whiteSpace: "nowrap",
            }}
          >
            {f}
          </div>
        ))}
      </div>

      {/* Coming Soon */}
      <div
        style={{
          marginTop: IPHONE_H * 0.04,
          zIndex: 2,
          textAlign: "center",
        }}
      >
        <div
          style={{
            fontSize: IPHONE_W * 0.024,
            fontWeight: 600,
            color: BRAND.fgMuted,
            textTransform: "uppercase",
            letterSpacing: "0.12em",
            marginBottom: 20,
          }}
        >
          Coming Soon
        </div>
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            justifyContent: "center",
            gap: 14,
          }}
        >
          {comingSoon.map((f) => (
            <div
              key={f}
              style={{
                padding: "16px 32px",
                borderRadius: 100,
                background: "rgba(255,255,255,0.03)",
                border: "1px solid rgba(255,255,255,0.06)",
                color: BRAND.fgMuted,
                fontSize: IPHONE_W * 0.03,
                fontWeight: 500,
                whiteSpace: "nowrap",
              }}
            >
              {f}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Screenshot registry ───
const IPHONE_SCREENSHOTS = [
  { id: "hero", name: "Hero", component: Slide1 },
  { id: "terminal", name: "Terminal", component: Slide2 },
  { id: "multi-session", name: "Multi-Session", component: Slide3 },
  { id: "resilient", name: "Resilient", component: Slide4 },
  { id: "identity", name: "Identity", component: Slide5 },
  { id: "more", name: "More Features", component: Slide6 },
];

// ─── Preview card with ResizeObserver scaling ───
function ScreenshotPreview({
  slide,
  index,
  selectedSize,
  onExport,
}: {
  slide: (typeof IPHONE_SCREENSHOTS)[number];
  index: number;
  selectedSize: (typeof IPHONE_SIZES)[number];
  onExport: (el: HTMLDivElement, name: string) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const exportRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(0.2);

  // Scale the preview to fit the container
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const cw = entry.contentRect.width;
        setScale(cw / IPHONE_W);
      }
    });

    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  const SlideComponent = slide.component;
  const fileName = `${String(index + 1).padStart(2, "0")}-${slide.id}-${selectedSize.w}x${selectedSize.h}.png`;

  return (
    <div className="relative flex flex-col gap-3">
      {/* Preview */}
      <div
        ref={containerRef}
        className="relative cursor-pointer group"
        style={{
          aspectRatio: `${IPHONE_W}/${IPHONE_H}`,
          borderRadius: 12,
          overflow: "hidden",
          border: "1px solid rgba(255,255,255,0.08)",
        }}
        onClick={() =>
          exportRef.current && onExport(exportRef.current, fileName)
        }
      >
        <div
          style={{
            width: IPHONE_W,
            height: IPHONE_H,
            transform: `scale(${scale})`,
            transformOrigin: "top left",
          }}
        >
          <SlideComponent />
        </div>

        {/* Hover overlay */}
        <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <span className="text-white text-sm font-semibold px-4 py-2 bg-white/10 rounded-full backdrop-blur-sm">
            Click to Export
          </span>
        </div>
      </div>

      {/* Label */}
      <div className="text-center">
        <div className="text-white/60 text-xs font-mono">{fileName}</div>
      </div>

      {/* Offscreen export copy */}
      <div
        ref={exportRef}
        data-export-slide={slide.id}
        style={{
          position: "fixed",
          left: -9999,
          top: 0,
          width: IPHONE_W,
          height: IPHONE_H,
          fontFamily: "Inter, sans-serif",
          pointerEvents: "none",
        }}
      >
        <SlideComponent />
      </div>
    </div>
  );
}

// ─── Main page ───
export default function ScreenshotsPage() {
  const [selectedSizeIdx, setSelectedSizeIdx] = useState(0);
  const [exporting, setExporting] = useState<string | null>(null);
  const [exportingAll, setExportingAll] = useState(false);

  const selectedSize = IPHONE_SIZES[selectedSizeIdx];

  // Export a single slide
  const handleExport = useCallback(
    async (el: HTMLDivElement, fileName: string) => {
      setExporting(fileName);
      try {
        // Move on-screen for capture
        el.style.position = "absolute";
        el.style.left = "0px";
        el.style.opacity = "1";
        el.style.zIndex = "-1";

        const opts = {
          width: IPHONE_W,
          height: IPHONE_H,
          pixelRatio: 1,
          cacheBust: true,
        };

        // Double-call trick: first warms fonts/images
        await toPng(el, opts);
        const dataUrl = await toPng(el, opts);

        // Move back off-screen
        el.style.position = "fixed";
        el.style.left = "-9999px";
        el.style.opacity = "";
        el.style.zIndex = "";

        // If export size differs from design size, resize via canvas
        if (selectedSize.w !== IPHONE_W || selectedSize.h !== IPHONE_H) {
          const img = new Image();
          img.src = dataUrl;
          await new Promise((r) => (img.onload = r));

          const canvas = document.createElement("canvas");
          canvas.width = selectedSize.w;
          canvas.height = selectedSize.h;
          const ctx = canvas.getContext("2d")!;
          ctx.drawImage(img, 0, 0, selectedSize.w, selectedSize.h);

          const resized = canvas.toDataURL("image/png");
          triggerDownload(resized, fileName);
        } else {
          triggerDownload(dataUrl, fileName);
        }
      } catch (err) {
        console.error("Export failed:", err);
      } finally {
        setExporting(null);
      }
    },
    [selectedSize]
  );

  // Export all slides
  const handleExportAll = useCallback(async () => {
    setExportingAll(true);
    const exportEls = document.querySelectorAll<HTMLDivElement>(
      "[data-export-slide]"
    );

    for (let i = 0; i < exportEls.length; i++) {
      const el = exportEls[i];
      const slideId = el.dataset.exportSlide!;
      const fileName = `${String(i + 1).padStart(2, "0")}-${slideId}-${selectedSize.w}x${selectedSize.h}.png`;
      await handleExport(el, fileName);
      // 300ms delay between exports
      await new Promise((r) => setTimeout(r, 300));
    }

    setExportingAll(false);
  }, [handleExport, selectedSize]);

  return (
    <div
      className="min-h-screen relative"
      style={{ background: "#0a0a0a", color: "#e8eaf0", overflow: "hidden" }}
    >
      {/* Toolbar */}
      <div
        className="sticky top-0 z-50 flex items-center justify-between px-6 py-4 backdrop-blur-xl"
        style={{
          background: "rgba(10, 10, 10, 0.85)",
          borderBottom: "1px solid rgba(255,255,255,0.06)",
        }}
      >
        <div className="flex items-center gap-4">
          <h1 className="text-lg font-bold">Hoshi Screenshots</h1>
          <span className="text-white/30 text-sm">
            {IPHONE_SCREENSHOTS.length} slides
          </span>
        </div>

        <div className="flex items-center gap-4">
          {/* Size selector */}
          <div className="flex gap-1 bg-white/5 rounded-lg p-1">
            {IPHONE_SIZES.map((s, i) => (
              <button
                key={s.label}
                onClick={() => setSelectedSizeIdx(i)}
                className="px-3 py-1.5 text-xs font-mono rounded-md transition-colors"
                style={{
                  background:
                    i === selectedSizeIdx
                      ? "rgba(56, 120, 255, 0.2)"
                      : "transparent",
                  color:
                    i === selectedSizeIdx
                      ? BRAND.accent
                      : "rgba(255,255,255,0.5)",
                  border:
                    i === selectedSizeIdx
                      ? `1px solid ${BRAND.accent}`
                      : "1px solid transparent",
                }}
              >
                {s.label} ({s.w}&times;{s.h})
              </button>
            ))}
          </div>

          {/* Export all */}
          <button
            onClick={handleExportAll}
            disabled={exportingAll}
            className="px-4 py-2 text-sm font-semibold rounded-lg transition-colors"
            style={{
              background: exportingAll
                ? "rgba(56, 120, 255, 0.1)"
                : BRAND.accent,
              color: "#fff",
            }}
          >
            {exportingAll ? "Exporting..." : "Export All"}
          </button>
        </div>
      </div>

      {/* Status */}
      {(exporting || exportingAll) && (
        <div
          className="text-center py-2 text-sm"
          style={{
            background: "rgba(56, 120, 255, 0.1)",
            color: BRAND.accent,
          }}
        >
          {exporting ? `Exporting ${exporting}...` : "Exporting all slides..."}
        </div>
      )}

      {/* Grid of previews */}
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-6 p-8">
        {IPHONE_SCREENSHOTS.map((slide, i) => (
          <ScreenshotPreview
            key={slide.id}
            slide={slide}
            index={i}
            selectedSize={selectedSize}
            onExport={handleExport}
          />
        ))}
      </div>

      {/* Export containers are inside each ScreenshotPreview via data-export-slide */}
    </div>
  );
}

// ─── Download helper ───
function triggerDownload(dataUrl: string, fileName: string) {
  const a = document.createElement("a");
  a.href = dataUrl;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}
