#!/bin/sh
# Prepares a release locally: build, zip, signed appcast.json. Publishing is a separate, manual step.
#   tools/release.sh 0.1.0
# Needs the tag 0.1.0 on HEAD (bundle.sh takes the version from it) and the MinorUpdate key in the
# login Keychain (swift tools/minorupdate.swift keygen). The private key never leaves the Mac.
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: tools/release.sh X.Y.Z}
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must be major.minor.patch" >&2; exit 1; }
[ "$(git rev-parse "$VERSION^{commit}" 2>/dev/null)" = "$(git rev-parse HEAD)" ] || { echo "tag $VERSION must point at HEAD" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }

make bundle
ZIP="build/MinorIDE-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/MinorIDE.app "$ZIP"
URL="https://github.com/novami/minor-ide/releases/download/$VERSION/MinorIDE-$VERSION.zip"
NOTES=docs/release-notes/$VERSION.md
if [ -f "$NOTES" ]; then
	swift tools/minorupdate.swift sign "$ZIP" cz.novami.minoride "$VERSION" "$URL" "$NOTES" > build/appcast.json
else
	swift tools/minorupdate.swift sign "$ZIP" cz.novami.minoride "$VERSION" "$URL" > build/appcast.json
fi
echo "Ready: $ZIP and build/appcast.json. Publish with:"
echo "  gh release create $VERSION $ZIP build/appcast.json --title $VERSION --notes-file <notes>"
