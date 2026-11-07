#!/bin/bash
# Visual smoke test (host-side): build, install, launch, screenshot, assert.
#
# Catches render bugs the unit tests cannot see (e.g. the avatar drawing
# off-screen while every engine/golden test stays green). Run it after any
# renderer or stage change, and wire it into CI after the build job:
#
#   Tools/visual_smoke_test.sh ["AivatarFresh"]
#
# v23 repair: on a watch sim without a paired phone, the app only SOMETIMES
# gets the display (suspended-launch UI assertion is racy). When it does, it
# paints ~6-8 s after launch and stays lit for 20+ s. So: fresh boot per
# attempt, poll launch+3s..+21s, retry the whole boot up to 3x per archetype.
# -stageAwake only keeps the APP awake; it cannot keep the sim display lit.
# Captures are named <archetype>.png so Tools/assess_similarity.swift reads
# the same directory.

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

echo "==> Building"
cd "$ROOT"
# v23: capture build output first — piping through `grep -q` under pipefail
# can SIGPIPE the upstream grep and false-fail a green build.
BUILD_OUT="$(xcodebuild -project Aivatar.xcodeproj -scheme "Aivatar Watch App" \
     -destination "platform=watchOS Simulator,id=$UDID" build 2>&1 || true)"
if ! echo "$BUILD_OUT" | grep -q "BUILD SUCCEEDED"; then
  echo "FAIL: build failed"
  echo "$BUILD_OUT" | tail -20
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

# Precompile the analyzer once (the capture loop polls with it).
mkdir -p "$WORK/analyzer"
cp "$ROOT/Tools/visual_smoke.swift" "$WORK/analyzer/main.swift"
env -u SDKROOT xcrun --sdk macosx swiftc "$WORK/analyzer/main.swift" -o "$WORK/analyzer/analyze" 2>/dev/null

echo "==> Capturing all five archetypes (fresh boot per attempt, up to 3 attempts)"
installed=0
for a in ember willow compass prism nimbus; do
  got=0
  for attempt in 1 2 3; do
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl boot "$UDID"
    sleep 5
    if [ "$installed" = 0 ]; then
      xcrun simctl install "$UDID" "$APP"
      installed=1
    fi
    xcrun simctl launch "$UDID" "$BUNDLE" -archetype "$a" -stageAwake >/dev/null 2>&1 || true
    sleep 3
    best=0
    for try in $(seq 1 8); do
      xcrun simctl io "$UDID" screenshot "$WORK/try.png" >/dev/null 2>&1
      rm -rf "$WORK/trydir"; mkdir -p "$WORK/trydir"
      cp "$WORK/try.png" "$WORK/trydir/$a.png"
      line="$("$WORK/analyzer/analyze" "$WORK/trydir" 2>/dev/null | grep "^$a |" || true)"
      cov="$(echo "$line" | awk -F'|' '{gsub(/[% ]/,"",$2); print $2}')"
      if echo "$line" | grep -q " PASS"; then
        cp "$WORK/try.png" "$WORK/$a.png"; got=1; break
      fi
      if [ -n "$cov" ] && awk -v c="$cov" -v b="$best" 'BEGIN{exit !(c>b)}'; then
        best="$cov"
        cp "$WORK/try.png" "$WORK/$a.png"
      fi
      sleep 2
    done
    [ "$got" = 1 ] && break
  done
  echo "    $a: $([ "$got" = 1 ] && echo captured || echo 'no lit frame after 3 boots')"
done
xcrun simctl shutdown "$UDID" 2>/dev/null || true
rm -rf "$WORK/try.png" "$WORK/trydir"

echo "==> Analyzing"
set +e
"$WORK/analyzer/analyze" "$WORK"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: see per-archetype reasons above"
  exit 1
fi
