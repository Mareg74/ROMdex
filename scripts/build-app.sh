#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ROMdex"
VERSION="${1:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
BINARY_PATH="$ROOT/.build/release/$APP_NAME"
RESOURCE_BUNDLE="$ROOT/.build/release/${APP_NAME}_${APP_NAME}.bundle"

echo "→ Compilation release…"
swift build -c release

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Binaire introuvable : $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Bundle ressources introuvable : $RESOURCE_BUNDLE" >&2
  exit 1
fi

echo "→ Assemblage $APP_NAME.app…"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$APP_NAME"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/${APP_NAME}_${APP_NAME}.bundle"
cp "$ROOT/Sources/ROMdex/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.mareg74.romdex</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "→ $APP_PATH prêt ($(du -sh "$APP_PATH" | cut -f1))"
