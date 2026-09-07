#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
file="$ROOT/VERSION"
if [ ! -f "$file" ]; then
	echo "VERSION file is missing" >&2
	exit 1
fi

version=$(tr -d '[:space:]' < "$file")
case "$version" in
	''|*[!0-9.]*)
		echo "VERSION must be a dotted number like 1.0.0 (got '$version')" >&2
		exit 1
		;;
esac

printf '%s\n' "$version"
