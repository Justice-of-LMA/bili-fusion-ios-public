#!/bin/bash
# Stills of the explicitly enabled public-room test; no screen/video recording.
set -euo pipefail
DEVICE_ID=$1
APP_ID=$2
last_capture=0
count=0
login_delivered=0
for ((attempt=0; attempt<240; attempt++)); do
  container=$(xcrun simctl get_app_container "$DEVICE_ID" "$APP_ID" data 2>/dev/null || true)
  if [ "${FUSION_LIVE_LOGIN:-0}" = "1" ] && [ "$login_delivered" -eq 0 ] && [ -n "$container" ] && [ -f "$RUNNER_TEMP/fusion-live-login/session.json" ]; then
    mkdir -p "$container/Documents/live-login"
    cp "$RUNNER_TEMP/fusion-live-login/session.json" "$container/Documents/live-login/session.tmp"
    chmod 600 "$container/Documents/live-login/session.tmp"
    mv "$container/Documents/live-login/session.tmp" "$container/Documents/live-login/session.json"
    login_delivered=1
    printf 'Temporary user-authorized login delivered to iOS; no credentials logged.\n'
  fi
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
