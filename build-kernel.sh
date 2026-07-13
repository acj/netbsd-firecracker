#!/bin/sh

set -eu

NETBSD_MIRROR="${NETBSD_MIRROR:-https://cdn.netbsd.org/pub/NetBSD}"
MACHINE=amd64
KERNEL_CONFIG="${KERNEL_CONFIG:-FIRECRACKER}"

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASEDIR/work"
OUTDIR="$BASEDIR/out"
SRCDIR="$WORKDIR/usr/src"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

mkdir -p "$WORKDIR" "$OUTDIR"

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

if [ "$KERNEL_CONFIG" = "FIRECRACKER" ]; then
    cp "$BASEDIR/files/FIRECRACKER.conf" \
        "$SRCDIR/sys/arch/$MACHINE/conf/FIRECRACKER"
fi

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
