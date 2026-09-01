#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
TAG="${2:-v$VERSION}"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/ROMdex.app"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_RW="$BUILD_DIR/ROMdex-temp.dmg"
DMG_PATH="$BUILD_DIR/ROMdex.dmg"

"$ROOT/scripts/build-app.sh" "$VERSION"

echo "→ Préparation de l’image disque (ROMdex.app + raccourci Applications)…"
rm -rf "$DMG_STAGING" "$DMG_RW" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/ROMdex.app"
ln -s /Applications "$DMG_STAGING/Applications"

SIZE_MB=$(( $(du -sm "$DMG_STAGING" | cut -f1) + 20 ))
hdiutil create -volname "ROMdex" -srcfolder "$DMG_STAGING" -ov -format UDRW -size "${SIZE_MB}m" "$DMG_RW" >/dev/null

MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW" | awk '/\/Volumes\// {print $3; exit}')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Impossible de monter l’image disque temporaire." >&2
  exit 1
fi

cleanup() {
  if [[ -n "${MOUNT_DIR:-}" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "→ Mise en page de la fenêtre d’installation…"
osascript <<APPLESCRIPT || true
tell application "Finder"
  tell disk "ROMdex"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 620, 380}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    try
      set position of item "ROMdex.app" of container window to {130, 140}
    end try
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""
trap - EXIT

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW"
rm -rf "$DMG_STAGING"

echo "→ $DMG_PATH prêt ($(du -sh "$DMG_PATH" | cut -f1))"
echo ""
echo "Pour publier sur une release GitHub :"
echo "  gh release upload $TAG \"$DMG_PATH\" -R Mareg74/ROMdex --clobber"
