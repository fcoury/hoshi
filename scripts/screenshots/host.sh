#!/usr/bin/env bash
# Starts the Docker screenshot host (devbox, gpu-box, prod-api) and builds the
# deterministic tmux and Herdr state in each container.
#   scripts/screenshots/host.sh          build + start + setup
#   scripts/screenshots/host.sh setup    re-run setup only (reset agents)
#   scripts/screenshots/host.sh restart  restart containers + setup. Use before
#                                        every app launch: OrbStack's IPv6 UDP
#                                        forwarding wedges when a killed app
#                                        leaves a mosh-server talking to it.
#   scripts/screenshots/host.sh down     stop and remove the containers
# SHOTS_HOLD=1 makes the reviewer/writer agents wait for trigger.sh.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/assets/screenshot-host"
pwfile="$dir/.shots-password"

# Local test password for the throwaway containers; gitignored.
[ -s "$pwfile" ] || { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 >"$pwfile"; chmod 600 "$pwfile"; }
export SHOTS_PASSWORD; SHOTS_PASSWORD=$(cat "$pwfile")
compose() { docker compose -f "$dir/compose.yml" "$@"; }

case "${1:-up}" in
down) compose down; exit ;;
up)   compose up -d --build ;;
restart) docker restart shots-devbox shots-gpu-box shots-prod-api >/dev/null ;;
setup) ;;
*) echo "usage: $0 [up|restart|setup|down]" >&2; exit 2 ;;
esac

for c in devbox gpu-box prod-api; do
  for _ in $(seq 20); do docker exec "shots-$c" pgrep -x sshd >/dev/null 2>&1 && break; sleep 0.5; done
  echo "== $c"
  docker exec -u fcoury -e SHOTS_AGENTS="${SHOTS_AGENTS:-}" -e SHOTS_HOLD="${SHOTS_HOLD:-0}" \
    "shots-$c" bash -lc '/opt/shots/setup.sh'
done
