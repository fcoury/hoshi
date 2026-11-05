import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter", weight: ["500", "600", "700", "800"] });

export const metadata: Metadata = {
  title: "Hoshi App Store screenshots",
  description: "App Store screenshot generator for Hoshi",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={inter.variable}>
      <body style={{ margin: 0 }}>{children}</body>
    </html>
  );
}
