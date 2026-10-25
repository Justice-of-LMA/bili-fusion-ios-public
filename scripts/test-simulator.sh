#!/bin/bash
set -euo pipefail
APP_ID=${FUSION_BUNDLE_ID:-com.bilifusion.ios}
mkdir -p artifacts
xcodebuild -version > artifacts/test-environment.txt
xcrun simctl list devices available -j > artifacts/simulator-devices.json
DEVICE_ID=$(python3 scripts/select-simulator.py artifacts/simulator-devices.json)
printf 'Selected iPad simulator: %s\n' "$DEVICE_ID" >> artifacts/test-environment.txt
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
monitor_pid=""
cleanup_monitor(){ if [ -n "$monitor_pid" ]; then kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=""; fi; }
trap cleanup_monitor EXIT
if [ "${FUSION_LIVE_SOAK:-0}" = "1" ]; then
  bash scripts/monitor-live-soak.sh "$DEVICE_ID" "$APP_ID" > artifacts/live-soak-monitor.log 2>&1 &
  monitor_pid=$!
fi
test_status=0
xcodebuild -project Fusion.xcodeproj -scheme Fusion -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO FUSION_LIVE_SOAK="${FUSION_LIVE_SOAK:-0}" test > artifacts/simulator-tests.log 2>&1 || test_status=$?
APP_DATA=$(xcrun simctl get_app_container "$DEVICE_ID" "$APP_ID" data 2>/dev/null || true)
if [ -n "$APP_DATA" ] && [ -d "$APP_DATA/Documents/live-soak" ]; then cp -R "$APP_DATA/Documents/live-soak" artifacts/live-soak; fi
cleanup_monitor
if [ "$test_status" -ne 0 ]; then tail -120 artifacts/simulator-tests.log; exit "$test_status"; fi
xcrun simctl launch "$DEVICE_ID" "$APP_ID"
sleep 4
xcrun simctl io "$DEVICE_ID" screenshot artifacts/ipad-startup.png
APP_DATA=$(xcrun simctl get_app_container "$DEVICE_ID" "$APP_ID" data)
if [ -f "$APP_DATA/Documents/pip-list-qa.png" ]; then cp "$APP_DATA/Documents/pip-list-qa.png" artifacts/pip-list-qa.png; fi
if [ -d "$APP_DATA/Documents/ai-voice-effects" ]; then cp -R "$APP_DATA/Documents/ai-voice-effects" artifacts/ai-voice-effects; fi
