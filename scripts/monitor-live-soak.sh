#!/bin/bash
# Stills of the explicitly enabled public-room test; no screen/video recording.
set -euo pipefail
DEVICE_ID=$1
APP_ID=$2
last_capture=0
count=0
for ((attempt=0; attempt<100; attempt++)); do
  container=$(xcrun simctl get_app_container "$DEVICE_ID" "$APP_ID" data 2>/dev/null || true)
  marker="$container/Documents/live-soak/active.json"
  if [ -n "$container" ] && [ -f "$marker" ]; then
    active=$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1])).get("active") else "0")' "$marker" 2>/dev/null || true)
    if [ "$active" = "1" ]; then
      now=$(date +%s)
      if [ "$last_capture" -eq 0 ] || [ $((now-last_capture)) -ge 60 ]; then
        count=$((count+1))
        xcrun simctl io "$DEVICE_ID" screenshot "artifacts/live-soak-$count.png"
        printf 'Live-room still %s at UTC %s\n' "$count" "$(date -u +%FT%TZ)"
        last_capture=$now
      fi
    elif [ "$count" -gt 0 ]; then
      exit 0
    fi
  fi
  sleep 5
done
