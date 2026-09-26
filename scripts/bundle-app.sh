#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI="$ROOT/.build/release/Scanjet200"
CLI="$ROOT/.build/release/scanjet"
RESOURCES="$ROOT/.build/release/scanjet200_ScanjetCore.bundle"
APP="$ROOT/Scanjet 200.app"

if [ ! -f "$GUI" ] || [ ! -f "$CLI" ] || [ ! -d "$RESOURCES" ]; then
	echo "Build GUI and CLI first: swift build -c release" >&2
	exit 1
fi

VERSION="$("$ROOT/scripts/version.sh")"
BUILD="${SCANJET_BUILD:-$VERSION}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$GUI" "$APP/Contents/MacOS/Scanjet200"
cp "$CLI" "$APP/Contents/MacOS/scanjet"
chmod +x "$APP/Contents/MacOS/Scanjet200" "$APP/Contents/MacOS/scanjet"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Resources/scanjet200_ScanjetCore.bundle"
cp -R "$RESOURCES" "$APP/Contents/Resources/"
touch "$APP"

echo "Created $APP"
echo "  GUI:  open \"$APP\""
echo "  CLI:  \"$APP/Contents/MacOS/scanjet\""
