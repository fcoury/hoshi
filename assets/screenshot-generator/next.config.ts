import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The dev badge would otherwise land in every exported screenshot.
  devIndicators: false,
};

export default nextConfig;
