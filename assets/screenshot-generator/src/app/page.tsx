"use client";

// Gallery of every App Store slide, scaled to fit. `?export=<device>/<id>`
// renders one slide alone at its design size, which scripts/export.mjs
// screenshots with Playwright.
import { useEffect, useState } from "react";
import { CANVAS, type Device } from "@/lib/brand";
import { IPHONE_SLIDES } from "@/slides/iphone";
import { IPAD_SLIDES } from "@/slides/ipad";
import { PREVIEW_CARDS } from "@/slides/preview";
import { SOCIAL_CARDS } from "@/slides/social";
import { FILM_STAGES } from "@/slides/film";

const SETS: Record<Device, readonly { id: string; C: () => React.JSX.Element }[]> = {
  iphone: IPHONE_SLIDES,
  ipad: IPAD_SLIDES,
  preview: PREVIEW_CARDS,
  social: SOCIAL_CARDS,
  film: FILM_STAGES,
};

export default function Page() {
  const [target, setTarget] = useState<string | null | undefined>(undefined);
  useEffect(() => {
    setTarget(new URLSearchParams(window.location.search).get("export"));
  }, []);

  if (target === undefined) return null;
  if (target) {
    const [device, id] = target.split("/") as [Device, string];
    const slide = SETS[device]?.find((s) => s.id === id);
    if (!slide) return <div id="missing">unknown slide {target}</div>;
    const { w, h } = CANVAS[device];
    return (
      <div id="slide" style={{ width: w, height: h }}>
        <slide.C />
      </div>
    );
  }
  return <Gallery />;
}

function Gallery() {
  return (
    <div style={{ background: "#050608", minHeight: "100vh", color: "#e8eaf0", padding: 32 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Hoshi App Store screenshots</h1>
      <p style={{ opacity: 0.5, fontSize: 13, marginBottom: 28 }}>
        Export with <code>bun run export</code> (Playwright). Click a slide to open it at full size.
      </p>
      {(Object.keys(SETS) as Device[]).map((device) => (
        <section key={device} style={{ marginBottom: 48 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, opacity: 0.7, marginBottom: 14 }}>
            {{ iphone: "iPhone 6.9″ (1320×2868)", ipad: "iPad 13″ (2064×2752)", preview: "App Preview cards (886×1920)", social: "Social card (1200×630)", film: "Website film stages (1920×1080)" }[device]}
          </h2>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 20 }}>
            {SETS[device].map((s, i) => (
              <Thumb key={s.id} device={device} index={i} id={s.id} C={s.C} />
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

function Thumb({ device, index, id, C }: { device: Device; index: number; id: string; C: () => React.JSX.Element }) {
  const { w, h } = CANVAS[device];
  const width = device === "ipad" ? 300 : device === "social" || device === "film" ? 420 : 220;
  const scale = width / w;
  return (
    <a href={`?export=${device}/${id}`} style={{ textDecoration: "none", color: "inherit" }}>
      <div
        style={{
          width,
          height: h * scale,
          overflow: "hidden",
          borderRadius: 10,
          border: "1px solid rgba(255,255,255,0.08)",
        }}
      >
        <div style={{ width: w, height: h, transform: `scale(${scale})`, transformOrigin: "top left" }}>
          <C />
        </div>
      </div>
      <div style={{ fontSize: 11, fontFamily: "monospace", opacity: 0.55, marginTop: 6 }}>
        {String(index + 1).padStart(2, "0")}-{id}
      </div>
    </a>
  );
}
