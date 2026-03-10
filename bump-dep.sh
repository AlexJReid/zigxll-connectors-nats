#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.3.10" >&2
  exit 1
fi

V="$1"
ZON="build.zig.zon"

# Update the URL
sed -i '' "s|/zigxll/archive/refs/tags/v[^\"]*\.tar\.gz|/zigxll/archive/refs/tags/v${V}.tar.gz|" "$ZON"

# Set a dummy hash to force zig to report the real one
sed -i '' "s|\"xll-[^\"]*\"|\"xll-${V}-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"|" "$ZON"

# Fetch the correct hash from zig build output
REAL_HASH=$(zig build 2>&1 | grep -o "'xll-${V}-[^']*'" | tr -d "'" || true)

if [ -z "$REAL_HASH" ]; then
  echo "Error: could not determine hash for v${V}" >&2
  exit 1
fi

sed -i '' "s|\"xll-${V}-[^\"]*\"|\"${REAL_HASH}\"|" "$ZON"

echo "Bumped xll to v${V} (hash: ${REAL_HASH})"
