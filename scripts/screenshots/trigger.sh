#!/usr/bin/env bash
# Fires a held agent moment on devbox (needs SHOTS_HOLD=1 at setup):
#   trigger.sh start    builder starts working (SHOTS_HOLD=2, video)
#   trigger.sh block    reviewer asks for approval  -> "needs input" event
#   trigger.sh finish   writer finishes             -> "finished" event
#   trigger.sh reply T  answer the reviewer as if from Hoshi's Reply sheet
set -euo pipefail
case ${1:?start|block|finish|reply} in
start|block|finish) docker exec -u fcoury shots-devbox touch "/tmp/shots/$1" ;;
reply) docker exec -u fcoury shots-devbox bash -lc \
  "p=\$(herdr agent list | python3 -c 'import json,sys;print([a for a in json.load(sys.stdin)[\"result\"][\"agents\"] if a[\"agent_status\"]==\"blocked\"][0][\"pane_id\"])'); herdr agent send-keys \"\$p\" $(printf %q "${2:-yes}") Enter" ;;
esac
