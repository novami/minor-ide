#!/bin/sh
# Assembles build/MinorIDE.app from the SwiftPM release build and the Go helper.
# Signs ad hoc; Developer ID signing and notarization belong to the release workflow (phase 2).
set -eu
cd "$(dirname "$0")/.."

# Bundle versions must be numeric: use the latest vX.Y.Z tag, or 0.0.0 before the first release.
VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
VERSION=${VERSION#v}
[ -n "$VERSION" ] || VERSION=0.0.0
APP=build/MinorIDE.app

swift build -c release --build-system native --product MinorIDE
test -x server/bin/minoride-server || { echo "missing server/bin/minoride-server, run make server" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/MinorIDE "$APP/Contents/MacOS/MinorIDE"
cp server/bin/minoride-server "$APP/Contents/Helpers/minoride-server"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # drawn by tools/make-icon.swift

# Every Resources/<lang>.lproj becomes a declared localization (new languages need no edit here).
LOCALIZATIONS=""
for d in Resources/*.lproj; do LOCALIZATIONS="$LOCALIZATIONS<string>$(basename "$d" .lproj)</string>"; done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MinorIDE</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>cz.novami.minoride</string>
	<key>CFBundleName</key><string>MinorIDE</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Helpers first, then the app (inside-out signing).
codesign --force --sign - "$APP/Contents/Helpers/minoride-server"
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"
