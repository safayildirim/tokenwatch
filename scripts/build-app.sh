#!/bin/bash
# Builds "Tokenwatch.app" into ./build.
#
#   scripts/build-app.sh            optimized build for this Mac's architecture
#   scripts/build-app.sh --universal  universal binary (arm64 + x86_64)
#
# The app is signed ad hoc, which is enough to run it locally and to register it as a login item.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tokenwatch"
BUNDLE_ID="dev.tokenwatch.app"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> Compiling (release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Tokenwatch
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product tw
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product tw-statusline
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
mkdir -p "$BUILD_DIR"
# Keeps Spotlight from listing this build output as a second copy of the app next to the installed one.
touch "$BUILD_DIR/.metadata_never_index"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tokenwatch" "$APP/Contents/MacOS/Tokenwatch"
cp "$BIN_DIR/tw-statusline" "$APP/Contents/MacOS/tw-statusline"
cp "$BIN_DIR/tw" "$APP/Contents/MacOS/tw"

echo "==> Localizations"
# The app follows the system language: macOS picks Turkish when it comes before English in the user's list of
# preferred languages (or when Tokenwatch is set to Turkish under Language & Region), and English otherwise.
cp -R Localization/en.lproj Localization/tr.lproj "$APP/Contents/Resources/"

echo "==> Icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
    <key>CFBundleExecutable</key><string>Tokenwatch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. No data leaves this Mac.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/tw-statusline"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/tw"
codesign --force --sign - --timestamp=none --options runtime "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -2

echo "==> Done: $APP"
