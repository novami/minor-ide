#!/bin/sh
# Assembles build/MinorIDE.app from the SwiftPM release build and the Go helper.
# Signs ad hoc; Developer ID signing and notarization belong to the release workflow (phase 2).
set -eu
cd "$(dirname "$0")/.."

# The version is plain major.minor.patch (no prefix, no hash): the latest X.Y.Z tag, or 0.0.0 before the first release.
VERSION=$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
[ -n "$VERSION" ] || VERSION=0.0.0
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "tag $VERSION is not major.minor.patch" >&2; exit 1; }
APP=build/MinorIDE.app

swift build -c release --build-system native --product MinorIDE
test -x server/bin/minoride-server || { echo "missing server/bin/minoride-server, run make server" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/MinorIDE "$APP/Contents/MacOS/MinorIDE"
cp server/bin/minoride-server "$APP/Contents/Helpers/minoride-server"
# Language files, one empty <lang>.lproj per language (system UI follows it) and InfoPlist.strings.
LPROJS=$(swift run -q --build-system native L10nTool bundle "$APP/Contents/Resources")
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # drawn by tools/make-icon.swift
cp -R Resources/Licenses "$APP/Contents/Resources/" # licenses of bundled third-party code

# Help Book (Help › MinorIDE Help): pages from Resources/Help, indexed for Help Viewer and menu search.
HELP="$APP/Contents/Resources/MinorIDE.help/Contents"
mkdir -p "$HELP/Resources"
cp -R Resources/Help/* "$HELP/Resources/"
for d in "$HELP"/Resources/*.lproj; do
	hiutil -I corespotlight -Caf "$d/MinorIDE.cshelpindex" "$d" 2>/dev/null
	hiutil -I lsm -Caf "$d/MinorIDE.helpindex" "$d" 2>/dev/null
done
cat > "$HELP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleIdentifier</key><string>cz.novami.minoride.help</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>MinorIDE Help</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleSignature</key><string>hbwr</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>HPDBookAccessPath</key><string>index.html</string>
	<key>HPDBookCSIndexPath</key><string>MinorIDE.cshelpindex</string>
	<key>HPDBookIndexPath</key><string>MinorIDE.helpindex</string>
	<key>HPDBookTitle</key><string>MinorIDE Help</string>
	<key>HPDBookType</key><string>3</string>
</dict>
</plist>
EOF

# Every language file becomes a declared localization (new languages need no edit here).
LOCALIZATIONS=""
for l in $LPROJS; do LOCALIZATIONS="$LOCALIZATIONS<string>$l</string>"; done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MinorIDE</string>
	<key>CFBundleHelpBookFolder</key><string>MinorIDE.help</string>
	<key>CFBundleHelpBookName</key><string>cz.novami.minoride.help</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>cz.novami.minoride</string>
	<key>CFBundleName</key><string>MinorIDE</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 Michal Novák</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Helpers first, then the app (inside-out signing).
codesign --force --sign - "$APP/Contents/Helpers/minoride-server"
codesign --force --sign - "$APP"
# The bundle is recreated each time: refresh the Finder icon cache and LaunchServices.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "built $APP ($VERSION)"
