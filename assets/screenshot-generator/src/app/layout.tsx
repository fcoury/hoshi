import type { Metadata } from "next";
import { Fraunces, Inter, JetBrains_Mono, Shantell_Sans } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter", weight: ["500", "600", "700", "800"] });
// App Preview title cards.
const mono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono", weight: ["400", "500", "700", "800"] });
// gethoshi.app social card: the site's display and handwriting faces.
const fraunces = Fraunces({ subsets: ["latin"], variable: "--font-fraunces", axes: ["SOFT", "WONK", "opsz"], style: ["normal", "italic"] });
const hand = Shantell_Sans({ subsets: ["latin"], variable: "--font-hand" });

export const metadata: Metadata = {
  title: "Hoshi App Store screenshots",
  description: "App Store screenshot generator for Hoshi",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable} ${fraunces.variable} ${hand.variable}`}>
      <body style={{ margin: 0 }}>{children}</body>
    </html>
  );
}
