#!/usr/bin/env bash
# Build (unless SKIP_BUILD=1), prepare a simulator and launch Hoshi seeded.
#   scripts/screenshots/run.sh iphone-6.3
set -euo pipefail
source "$(dirname "$0")/lib.sh"
device=${1:-iphone-6.3}
udid=$(device_udid "$device")
[ "${SKIP_BUILD:-0}" = 1 ] || build_app
prepare_sim "$udid"
app_defaults "$udid"
launch_app "$udid"
echo "$udid"
