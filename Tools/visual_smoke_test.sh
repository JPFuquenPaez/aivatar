#!/bin/bash
# Visual smoke test (host-side): build, install, launch, screenshot, assert.
#
# Catches render bugs the unit tests cannot see (e.g. the avatar drawing
# off-screen while every engine/golden test stays green). Run it after any
# renderer or stage change, and wire it into CI after the build job:
#
#   Tools/visual_smoke_test.sh ["Apple Watch SE 3 (44mm)"]
#
# Uses a fresh simulator boot: the sim dims to always-on after ~15 s idle,
# and dimmed screenshots show the watch face, not the app.

set -euo pipefail

DEVICE="${1:-Apple Watch SE 3 (44mm)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="aivatarapp.Aivatar.watchkitapp"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aivatar-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

UDID="$(xcrun simctl list devices | grep "$DEVICE" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)"
if [ -z "$UDID" ]; then
  echo "FAIL: simulator device '$DEVICE' not found"
  exit 1
fi
echo "==> Device: $DEVICE ($UDID)"

echo "==> Fresh boot (avoids the dimmed always-on state)"
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl boot "$UDID"
sleep 15

echo "==> Building"
cd "$ROOT"
if ! xcodebuild -project Aivatar.xcodeproj -scheme "Aivatar Watch App" \
     -destination "platform=watchOS Simulator,id=$UDID" build 2>&1 \
     | grep -E "BUILD SUCCEEDED|BUILD FAILED" | grep -q "BUILD SUCCEEDED"; then
  echo "FAIL: build failed"
  exit 1
fi

BUILT="$(xcodebuild -project Aivatar.xcodeproj -scheme "Aivatar Watch App" \
  -destination "platform=watchOS Simulator,id=$UDID" -showBuildSettings 2>/dev/null \
  | sed -n 's/^ *BUILT_PRODUCTS_DIR *= *//p' | head -1)"
APP="$BUILT/Aivatar Watch App.app"
if [ -z "$BUILT" ] || [ ! -d "$APP" ]; then
  echo "FAIL: built app not found at '$APP'"
  exit 1
fi
xcrun simctl install "$UDID" "$APP"

echo "==> Capturing all five archetypes"
for a in ember willow compass prism nimbus; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" -archetype "$a" >/dev/null
  sleep 4
  xcrun simctl io "$UDID" screenshot "$WORK/smoke-$a.png" >/dev/null 2>&1
done

echo "==> Analyzing"
set +e
env -u SDKROOT xcrun --sdk macosx swift "$ROOT/Tools/visual_smoke.swift" "$WORK"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: see per-archetype reasons above"
  exit 1
fi
