#!/usr/bin/env bash
# Builds Mahfin.app (native macOS) into macos/build/. Run on a Mac with
# Homebrew's mpv and dylibbundler installed — CI does exactly that
# (.github/workflows/build-macos-native.yml); nothing is built locally.
#
#   VERSION=1.2.0 macos/build.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(cat ../VERSION)}"
ARCH="$(uname -m)"
BREW="$(brew --prefix)"
OUT=build
APP="$OUT/Mahfin.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# One module, compiled in one go. libmpv comes in through the bridging header,
# which is all a Swift app needs to call a C library.
swiftc -O -whole-module-optimization \
  -target "${ARCH}-apple-macos12.0" \
  -module-name Mahfin -parse-as-library -Xcc -DGL_SILENCE_DEPRECATION \
  -import-objc-header Sources/Bridging.h \
  -I "$BREW/include" -L "$BREW/lib" -lmpv \
  -framework AppKit -framework WebKit -framework OpenGL -framework QuartzCore \
  -framework AVFoundation -framework CoreMedia -framework VideoToolbox -framework Network \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift Sources/Native/*.swift \
  -o "$APP/Contents/MacOS/Mahfin"

sed "s/@VERSION@/${VERSION}/g" Resources/Info.plist.in > "$APP/Contents/Info.plist"
cp Resources/mahfin.icns "$APP/Contents/Resources/"
cp Sources/Bridge.js "$APP/Contents/Resources/"
# Mahfin's fonts for the native pages (OFL; licences beside them).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# mpv verifies https against this list (a copied-in libmpv cannot use the
# keychain). Homebrew's, else the system's own LibreSSL bundle.
if [ -f "$BREW/etc/ca-certificates/cert.pem" ]; then
  cp "$BREW/etc/ca-certificates/cert.pem" "$APP/Contents/Resources/cacert.pem"
else
  cp /etc/ssl/cert.pem "$APP/Contents/Resources/cacert.pem"
fi

# libmpv and everything it links, copied in with their install names rewritten
# to @executable_path/../Frameworks, so the app runs on a Mac with no Homebrew.
dylibbundler --overwrite-dir --bundle-deps --create-dir \
  --fix-file "$APP/Contents/MacOS/Mahfin" \
  --dest-dir "$APP/Contents/Frameworks" \
  --install-path @executable_path/../Frameworks/ \
  >/dev/null

# Ad-hoc signature, innermost first. Without an Apple Developer ID this is the
# most that can be done; Gatekeeper still asks on first open.
find "$APP/Contents/Frameworks" -name '*.dylib' -exec codesign --force -s - {} +
codesign --force -s - "$APP"
codesign --verify --strict --verbose=2 "$APP"

du -sh "$APP"
echo "built $APP ($VERSION, $ARCH)"
