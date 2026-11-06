// Brand tokens shared by every slide. Navy/near-black with the Hoshi blue and
// gold, matching the app icon and gethoshi.app.
export const BRAND = {
  bg: "#07090f",
  bgTop: "#0d1424",
  panel: "#121826",
  fg: "#eef1f7",
  fgMuted: "#8a93a8",
  fgDim: "#5b6478",
  accent: "#3878ff",
  accentSoft: "rgba(56, 120, 255, 0.16)",
  accentGlow: "rgba(56, 120, 255, 0.35)",
  gold: "#e8c66b",
  goldGlow: "rgba(232, 198, 107, 0.28)",
  green: "#5fd38d",
  orange: "#ff9f43",
} as const;

// Design canvases: the largest size Apple accepts per family. Exports to the
// other sizes are resized by scripts/export.mjs.
export const CANVAS = {
  iphone: { w: 1320, h: 2868 },
  ipad: { w: 2064, h: 2752 },
  // App Preview video title cards (6.9" App Preview size).
  preview: { w: 886, h: 1920 },
  // gethoshi.app social card (og:image).
  social: { w: 1200, h: 630 },
} as const;

export type Device = keyof typeof CANVAS;

// Native capture sizes (simctl screenshots), used to place crops.
export const CAPTURE = {
  iphone: { w: 1206, h: 2622 },
  ipad: { w: 2064, h: 2752 },
} as const;

// Export targets per device (App Store Connect display types).
export const EXPORTS = {
  iphone: [
    // App Store Connect scales this set to every smaller iPhone.
    { name: "iphone-6.9", w: 1320, h: 2868, ascType: "IPHONE_69" },
  ],
  ipad: [{ name: "ipad-13", w: 2064, h: 2752, ascType: "IPAD_PRO_3GEN_129" }],
} as const;
