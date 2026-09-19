#!/usr/bin/env sh
# Mahfin Desktop - macOS bundling script
# Run build.sh first
set -eu

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# Check build exists
if [ ! -d "${BUILD_DIR}/src/${APP_NAME}" ]; then
    echo "error: Build not found. Run build.sh first" >&2
    exit 1
fi

cd "${BUILD_DIR}"

# Install (runs macdeployqt to bundle Qt frameworks)
echo "Bundling Qt frameworks..."
ninja install

APP_BUNDLE="${BUILD_DIR}/output/${APP_NAME}"

echo "Signing app bundle..."
# Inside out, and not with --deep. See the same block in
# .github/workflows/build-macos.yml for why: --deep is deprecated for signing
# and does not treat the nested QtWebEngineProcess.app as a bundle of its own.
# Hygiene, plus a check that the seal is valid -- neither of which is what
# decides whether Gatekeeper lets the app open.
find "${APP_BUNDLE}/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -exec codesign --force -s - {} +
find "${APP_BUNDLE}/Contents" -type d -name '*.app' -exec codesign --force -s - {} +
find "${APP_BUNDLE}/Contents" -type d -name '*.framework' -exec codesign --force -s - {} +
codesign --force -s - "${APP_BUNDLE}"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "Creating DMG..."
VERSION="$(cat "${PROJECT_ROOT}/VERSION")"
ARCH="$(uname -m)"
DMG_NAME="MahfinDesktop-${VERSION}-${ARCH}.dmg"
# Shown by the Finder before the disk image mounts, and the only place the
# Gatekeeper steps can be put where somebody installing this is certain to
# see them: the app is ad-hoc signed, so the first launch is refused and the
# way out of that is four steps deep in System Settings.
EULA_FILE="${PROJECT_ROOT}/bundle/osx/first-launch.txt"
rm -f "${DMG_NAME}"
create-dmg \
    --volname "Mahfin Desktop v${VERSION}" \
    --no-internet-enable \
    --eula "${EULA_FILE}" \
    --background "${PROJECT_ROOT}/bundle/osx/dmg-background.tiff" \
    --window-size 700 520 \
    --icon-size 100 \
    --icon "Mahfin Desktop.app" 170 195 \
    --app-drop-link 530 195 \
    "${DMG_NAME}" "${APP_BUNDLE}"

echo ""
echo "Bundle complete!"
echo "DMG: ${BUILD_DIR}/${DMG_NAME}"
