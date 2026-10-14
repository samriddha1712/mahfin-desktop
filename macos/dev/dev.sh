#!/usr/bin/env zsh
# Builds MahfinDev.app for testing the native pages on a Mac without libmpv:
# the player is a stub (DevStubs.swift), everything else is the real app, with
# the release bundle id so it shares the signed-in session. Never shipped —
# build.sh compiles Sources/ only.
#
#   macos/dev/dev.sh [out-dir]
#   MAHFIN_DEV_STEPS="wait:8;scrollbench;open:/item/<id>;wait:4;shot2:/tmp/a.png;quit" \
#     <out-dir>/MahfinDev.app/Contents/MacOS/Mahfin
#
# Steps (DevAutomation.swift): wait:s, open:/path, nav:method (window.__mahfinNav),
# scrollto:y, scrollbench (10 momentum flicks, frame gaps from the display link),
# shot:/png (layer render), shot2:/png (AppKit drawing), frames, layers, quit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build-dev}"
APP="$OUT/MahfinDev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SRC=(${(f)"$(ls Sources/*.swift | grep -v -E 'MpvPlayer|VideoLayer')"})
xcrun swiftc -O -parse-as-library -module-name Mahfin -Xcc -DGL_SILENCE_DEPRECATION \
  -framework AppKit -framework WebKit -framework QuartzCore \
  -framework AVFoundation -framework CoreMedia -framework VideoToolbox -framework Network \
  $SRC Sources/Native/*.swift dev/DevStubs.swift dev/DevAutomation.swift \
  -o "$APP/Contents/MacOS/Mahfin"
sed "s/@VERSION@/0.0.0-dev/g" Resources/Info.plist.in > "$APP/Contents/Info.plist"
cp Resources/mahfin.icns Sources/Bridge.js "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
codesign --force -s - "$APP"
echo "built $APP"
