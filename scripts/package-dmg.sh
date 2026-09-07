#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Scanjet 200.app"

if [ $# -ge 1 ]; then
	DMG="$1"
else
	DMG="$ROOT/Scanjet-200-$("$ROOT/scripts/version.sh").dmg"
fi
case "$DMG" in
	/*) ;;
	*) DMG="$(pwd)/$DMG" ;;
esac

if [ ! -d "$APP" ]; then
	echo "Bundle the app first: ./scripts/bundle-app.sh" >&2
	exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/scanjet-dmg.XXXXXX")"
cleanup() {
	rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/Scanjet 200.app"
ln -s /Applications "$STAGE/Applications"

if [ -d "/Volumes/Scanjet 200" ]; then
	hdiutil detach "/Volumes/Scanjet 200" -quiet >/dev/null 2>&1 || true
fi

i=0
while true; do
	if hdiutil create \
		-volname "Scanjet 200" \
		-srcfolder "$STAGE" \
		-ov \
		-format UDZO \
		-imagekey zlib-level=9 \
		"$DMG"
	then
		break
	fi
	i=$((i + 1))
	if [ "$i" -ge 5 ]; then
		echo "hdiutil failed after $i attempts" >&2
		exit 1
	fi
	echo "hdiutil failed, retrying ($i)..." >&2
	sleep 2
done

echo "Created $DMG"
echo "  open \"$DMG\""
