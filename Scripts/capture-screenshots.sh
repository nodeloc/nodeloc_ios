#!/bin/bash
#
# Captures App Store screenshots at the two sizes Apple requires for this app.
#
# Apple scales one set down for every other display size, so only these two are
# mandatory:
#   iPhone 6.9"  1320 x 2868   (iPhone 17 Pro Max)
#   iPad 13"     2064 x 2752   (iPad Pro 13-inch)
#
# The app opens on its auth screen and `simctl` has no tap command, so the
# screens are requested through the `-screenshotMode` launch arguments (see
# ScreenshotMode.swift, DEBUG only) rather than by driving the UI.
#
# Usage:  Scripts/capture-screenshots.sh [output-dir]
#
set -uo pipefail

OUT="${1:-Screenshots}"
BUNDLE="com.nodeloc.app"
DERIVED="/tmp/screenshot-build"

IPHONE="iPhone 17 Pro Max"
IPAD="iPad Pro 13-inch (M5)"

# Time for the feed to fetch and images to decode before the shutter.
SETTLE=9
SETTLE_TOPIC=14

# The store listing gets one set of screenshots for every localization, so this
# picks which language they show. NodeLoc is a Chinese-language community.
LANG_CODE="${LANG_CODE:-zh-Hans}"
LOCALE_CODE="${LOCALE_CODE:-zh_CN}"

mkdir -p "$OUT"

udid_for() { xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'; }

shoot() {          # shoot <udid> <file> <settle> [launch args...]
    local udid="$1" file="$2" settle="$3"; shift 3
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
    # -AppleLanguages forces the app's language regardless of the simulator's
    # own setting. It matters twice: the UI, and the post bodies — the site
    # auto-translates content based on the request locale, so an English
    # simulator produces an English-looking Chinese forum.
    xcrun simctl launch "$udid" "$BUNDLE" \
        -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_CODE" \
        -screenshotMode "$@" >/dev/null
    sleep "$settle"
    xcrun simctl io "$udid" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
    local dims
    dims=$(python3 -c "
from struct import unpack
d=open('$OUT/$file','rb').read()
w,h=unpack('>II', d[16:24]); print(f'{w}x{h}')" 2>/dev/null || echo "?")
    printf '  %-34s %s\n' "$file" "$dims"
}

build_and_install() {   # build_and_install <udid> <label>
    local udid="$1" label="$2"
    echo "== $label: build + install"
    xcodebuild -project nodeloc.xcodeproj -scheme nodeloc -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$DERIVED" build >/tmp/screenshot-build.log 2>&1
    if ! grep -q "BUILD SUCCEEDED" /tmp/screenshot-build.log; then
        echo "   build failed — see /tmp/screenshot-build.log"; return 1
    fi
    xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/nodeloc.app"
}

IPHONE_UDID=$(udid_for "$IPHONE")
IPAD_UDID=$(udid_for "$IPAD")
echo "iPhone: $IPHONE  ($IPHONE_UDID)"
echo "iPad:   $IPAD  ($IPAD_UDID)"

for u in "$IPHONE_UDID" "$IPAD_UDID"; do
    xcrun simctl boot "$u" >/dev/null 2>&1
done
open -a Simulator
sleep 8

# Light appearance reads better in the store listing than whatever the host is set to.
for u in "$IPHONE_UDID" "$IPAD_UDID"; do
    xcrun simctl ui "$u" appearance light >/dev/null 2>&1
    # A clean status bar: full battery, no carrier noise.
    xcrun simctl status_bar "$u" override --time "9:41" --batteryState charged --batteryLevel 100 \
        --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 >/dev/null 2>&1
done

build_and_install "$IPHONE_UDID" "iPhone" || exit 1
echo "== iPhone 6.9\" captures"
shoot "$IPHONE_UDID" "iphone-1-feed.png"    "$SETTLE"
shoot "$IPHONE_UDID" "iphone-2-post.png"    "$SETTLE_TOPIC" -screenshotTopic 106076
shoot "$IPHONE_UDID" "iphone-3-nodes.png"   "$SETTLE" -screenshotTab nodes
shoot "$IPHONE_UDID" "iphone-4-sidebar.png" "$SETTLE" -screenshotSidebar
shoot "$IPHONE_UDID" "iphone-5-search.png"  "$SETTLE" -screenshotTab search

build_and_install "$IPAD_UDID" "iPad" || exit 1
echo "== iPad 13\" captures (portrait)"
shoot "$IPAD_UDID" "ipad-1-feed.png"  "$SETTLE"
shoot "$IPAD_UDID" "ipad-2-post.png"  "$SETTLE_TOPIC" -screenshotTopic 106076
shoot "$IPAD_UDID" "ipad-3-nodes.png" "$SETTLE" -screenshotTab nodes

echo
echo "Written to $OUT/"
echo "NOTE: iPad landscape (pinned sidebar) needs a manual rotate —"
echo "      Simulator > Device > Rotate Left, then re-run the iPad shots."
