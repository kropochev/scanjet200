#!/bin/sh
# Compile-time version: writes Sources/ScanjetCore/AppVersion.swift from VERSION.
# Optional SCANJET_BUILD overrides CFBundleVersion / AppVersion.build (CI run number).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/version.sh")"
BUILD="${SCANJET_BUILD:-$VERSION}"
case "$BUILD" in
	''|*[!0-9.]*)
		echo "SCANJET_BUILD must be a dotted number like 1.0.0 (got '$BUILD')" >&2
		exit 1
		;;
esac

out="$ROOT/Sources/ScanjetCore/AppVersion.swift"
tmp="$out.tmp"
cat > "$tmp" << EOF
/// Generated from \`VERSION\` by \`scripts/embed-version.sh\`. Do not edit.
public enum AppVersion: Sendable {
    public static let marketing = "$VERSION"
    public static let build = "$BUILD"

    public static var display: String {
        if build == marketing { return marketing }
        return "\\(marketing) (\\(build))"
    }

    public static var cliLine: String {
        if build == marketing { return "scanjet \\(marketing)" }
        return "scanjet \\(marketing) (\\(build))"
    }
}
EOF
mv "$tmp" "$out"
echo "AppVersion $VERSION ($BUILD) → $out"
