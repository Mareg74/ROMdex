#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
TAG="${2:-v$VERSION}"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/ROMdex.app"
DMG_PATH="$BUILD_DIR/ROMdex-${VERSION}.dmg"

"$ROOT/scripts/build-app.sh" "$VERSION"

echo "→ Image disque ROMdex.app (affichage direct de l’application)…"
rm -f "$DMG_PATH"
hdiutil create -volname "ROMdex" -srcfolder "$APP_PATH" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null

echo "→ $DMG_PATH prêt ($(du -sh "$DMG_PATH" | cut -f1))"
echo ""
echo "Pour publier sur une release GitHub :"
echo "  gh release upload $TAG \"$DMG_PATH\" -R Mareg74/ROMdex --clobber"
