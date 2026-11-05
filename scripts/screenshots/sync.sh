#!/usr/bin/env bash
# Copies raw captures into the generator (public/shots/<iphone|ipad>/).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
pub="$root/assets/screenshot-generator/public/shots"
mkdir -p "$pub/iphone" "$pub/ipad"
[ -d "$root/.shots/raw/iphone-6.3" ] && cp "$root"/.shots/raw/iphone-6.3/*.png "$pub/iphone/"
[ -d "$root/.shots/raw/ipad-13" ] && cp "$root"/.shots/raw/ipad-13/*.png "$pub/ipad/"
ls "$pub"/*/ | wc -l | xargs echo "synced files:"
