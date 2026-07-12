#!/bin/sh
#
# Download a stock upstream Firecracker release binary. No fork needed:
# PVH boot (required for NetBSD) has been in mainline since v1.12.0.
#
# Outputs:
#   out/firecracker

set -eu

FIRECRACKER_VERSION="${FIRECRACKER_VERSION:-v1.16.1}"
ARCH=x86_64

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/out"
mkdir -p "$OUTDIR"

url="https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${ARCH}.tgz"

echo "Fetching Firecracker $FIRECRACKER_VERSION ..."
curl -fL "$url" | tar -xz -C "$OUTDIR" --strip-components=1 \
    "release-${FIRECRACKER_VERSION}-${ARCH}/firecracker-${FIRECRACKER_VERSION}-${ARCH}"
mv "$OUTDIR/firecracker-${FIRECRACKER_VERSION}-${ARCH}" "$OUTDIR/firecracker"
chmod +x "$OUTDIR/firecracker"

"$OUTDIR/firecracker" --version
