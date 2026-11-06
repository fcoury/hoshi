import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter", weight: ["500", "600", "700", "800"] });
// App Preview title cards.
const mono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-mono", weight: ["400", "500", "700", "800"] });

export const metadata: Metadata = {
  title: "Hoshi App Store screenshots",
  description: "App Store screenshot generator for Hoshi",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body style={{ margin: 0 }}>{children}</body>
    </html>
  );
}
