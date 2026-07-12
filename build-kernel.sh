#!/bin/sh
#
# Cross-build the NetBSD MICROVM kernel from a Linux (or any POSIX) host.
#
# NetBSD's build.sh bootstraps its own toolchain, so the only host requirements
# are a C/C++ compiler, make, and ~10GB of disk. The resulting kernel is a raw
# ELF with a PVH note; Firecracker >= 1.12 boots it directly.
#
# Outputs:
#   out/netbsd-kern.bin   - the kernel image consumed by the action
#   work/tools/           - cross toolchain (reused by build-rootfs.sh for nbmakefs)

set -eu

# NetBSD 11.0 is the first release with PVH boot and the MICROVM kernel.
# Track the newest RC until 11.0 ships, then pin the release.
NETBSD_RELEASE="${NETBSD_RELEASE:-11.0_RC5}"
NETBSD_MIRROR="${NETBSD_MIRROR:-https://cdn.netbsd.org/pub/NetBSD}"
MACHINE=amd64
KERNEL_CONFIG="${KERNEL_CONFIG:-MICROVM}"

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASEDIR/work"
OUTDIR="$BASEDIR/out"
SRCDIR="$WORKDIR/usr/src"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

mkdir -p "$WORKDIR" "$OUTDIR"

# --- Fetch and extract source sets ------------------------------------------
# src + gnusrc are needed to build the tools; syssrc + sharesrc for the kernel.
for set in src gnusrc sharesrc syssrc; do
    tarball="$WORKDIR/$set.tgz"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $set.tgz ..."
        curl -fL -o "$tarball" \
            "$NETBSD_MIRROR/NetBSD-$NETBSD_RELEASE/source/sets/$set.tgz"
    fi
done

if [ ! -d "$SRCDIR" ]; then
    echo "Extracting source sets ..."
    for set in src gnusrc sharesrc syssrc; do
        tar -xzf "$WORKDIR/$set.tgz" -C "$WORKDIR"
    done
fi

# --- Optional local kernel config overlay ------------------------------------
# If GHA runners ever need quirks, put them in files/FIRECRACKER.conf (which
# should `include "arch/amd64/conf/MICROVM"`) instead of patching the tree,
# and set KERNEL_CONFIG=FIRECRACKER.
if [ "$KERNEL_CONFIG" = "FIRECRACKER" ]; then
    cp "$BASEDIR/files/FIRECRACKER.conf" \
        "$SRCDIR/sys/arch/$MACHINE/conf/FIRECRACKER"
fi

# --- Build tools + kernel -----------------------------------------------------
cd "$SRCDIR"

./build.sh -U -m "$MACHINE" -j "$JOBS" \
    -T "$WORKDIR/tools" -O "$WORKDIR/obj" -D "$WORKDIR/dest" -R "$WORKDIR/rel" \
    tools

./build.sh -U -m "$MACHINE" -j "$JOBS" \
    -T "$WORKDIR/tools" -O "$WORKDIR/obj" -D "$WORKDIR/dest" -R "$WORKDIR/rel" \
    "kernel=$KERNEL_CONFIG"

cp "$WORKDIR/obj/sys/arch/$MACHINE/compile/$KERNEL_CONFIG/netbsd" \
    "$OUTDIR/netbsd-kern.bin"

echo "Kernel written to $OUTDIR/netbsd-kern.bin"
file "$OUTDIR/netbsd-kern.bin" || true
