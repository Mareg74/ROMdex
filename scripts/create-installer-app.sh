#!/usr/bin/env bash
set -euo pipefail

# Crée Install ROMdex.app — copie dans /Applications et retire la quarantaine Safari.
create_installer_app() {
    local staging_dir="$1"
    local source_app="$2"
    local icon_path="$3"
    local installer_path="$staging_dir/Install ROMdex.app"

    rm -rf "$installer_path"
    mkdir -p "$installer_path/Contents/MacOS"
    mkdir -p "$installer_path/Contents/Resources"

    cat > "$installer_path/Contents/MacOS/install" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

VOLUME="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCE="$VOLUME/ROMdex.app"
TARGET="/Applications/ROMdex.app"

if [[ ! -d "$SOURCE" ]]; then
    osascript -e 'display alert "ROMdex" message "ROMdex.app est introuvable sur le volume d’installation." as critical'
    exit 1
fi

ditto "$SOURCE" "$TARGET"
xattr -cr "$TARGET"
open "$TARGET"
SCRIPT
    chmod +x "$installer_path/Contents/MacOS/install"

    if [[ -f "$icon_path" ]]; then
        cp "$icon_path" "$installer_path/Contents/Resources/AppIcon.icns"
    fi

    cat > "$installer_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>install</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.mareg74.romdex.installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Install ROMdex</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

    codesign --force --deep --sign - "$installer_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    create_installer_app "${1:?}" "${2:?}" "${3:-}"
fi
