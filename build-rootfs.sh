#!/bin/sh

set -eu

NETBSD_RELEASE="${NETBSD_RELEASE:-11.0_RC5}"
NETBSD_MIRROR="${NETBSD_MIRROR:-https://cdn.netbsd.org/pub/NetBSD}"
PKGSRC_MIRROR="${PKGSRC_MIRROR:-https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/x86_64/11.0/All}"
MACHINE=amd64
IMAGE_SIZE="${IMAGE_SIZE:-2g}"

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASEDIR/work"
OUTDIR="$BASEDIR/out"
ROOTDIR="$WORKDIR/rootfs"
MAKEFS="$WORKDIR/tools/bin/nbmakefs"

if [ ! -x "$MAKEFS" ]; then
    echo "error: $MAKEFS not found; run build-kernel.sh first (it builds the toolchain)" >&2
    exit 1
fi
if [ ! -f "$OUTDIR/netbsd.id_rsa.pub" ]; then
    echo "error: $OUTDIR/netbsd.id_rsa.pub not found; run generate-ssh-key.sh first" >&2
    exit 1
fi

rm -rf "$ROOTDIR"
mkdir -p "$ROOTDIR" "$OUTDIR"

# base + etc are enough for a basic CI runner. We can add comp.tgz if a compiler is needed
for set in base etc; do
    tarball="$WORKDIR/$set.tgz"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $set.tgz ..."
        curl -fL -o "$tarball" \
            "$NETBSD_MIRROR/NetBSD-$NETBSD_RELEASE/$MACHINE/binary/sets/$set.tgz"
    fi
    tar -xzpf "$tarball" -C "$ROOTDIR"
done

[ -f "$ROOTDIR/dev/MAKEDEV" ] || cp "$ROOTDIR/etc/MAKEDEV" "$ROOTDIR/dev/MAKEDEV" 2>/dev/null || true

install -m 644 "$BASEDIR/files/rc.conf" "$ROOTDIR/etc/rc.conf"
install -m 555 "$BASEDIR/files/fcnet"   "$ROOTDIR/etc/rc.d/fcnet"

cat > "$ROOTDIR/etc/fstab" <<EOF
/dev/ld0a / ffs rw 1 1
EOF

cat > "$ROOTDIR/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

echo "netbsd-firecracker" > "$ROOTDIR/etc/myname"

mkdir -p "$ROOTDIR/root/.ssh"
chmod 700 "$ROOTDIR/root/.ssh"
install -m 600 "$OUTDIR/netbsd.id_rsa.pub" "$ROOTDIR/root/.ssh/authorized_keys"
cat >> "$ROOTDIR/etc/ssh/sshd_config" <<EOF
PermitRootLogin prohibit-password
UseDNS no
EOF

mkdir -p "$ROOTDIR/var/db"
dd if=/dev/urandom of="$ROOTDIR/var/db/entropy-file" bs=512 count=1 2>/dev/null
chmod 600 "$ROOTDIR/var/db/entropy-file"

RSYNC_PKGS="${RSYNC_PKGS:-rsync}"
mkdir -p "$ROOTDIR/usr/pkg"
for pkg in $RSYNC_PKGS; do
    pkgfile="$WORKDIR/$pkg.tgz"
    if [ ! -f "$pkgfile" ]; then
        pkgname="$(curl -fsL "$PKGSRC_MIRROR/" | grep -o "${pkg}-[0-9][^\"]*\.tgz" | sort -V | tail -1)"
        [ -n "$pkgname" ] || { echo "error: could not resolve $pkg on $PKGSRC_MIRROR" >&2; exit 1; }
        echo "Fetching $pkgname ..."
        curl -fL -o "$pkgfile" "$PKGSRC_MIRROR/$pkgname"
    fi
    tar -xzf "$pkgfile" -C "$ROOTDIR/usr/pkg" --exclude '+*'
done
# Avoid PATH weirdness when invoking rsync over ssh
ln -sf ../pkg/bin/rsync "$ROOTDIR/usr/bin/rsync"

"$MAKEFS" -t ffs -B le -s "$IMAGE_SIZE" -o density=8192 \
    "$OUTDIR/netbsd-rootfs.bin" "$ROOTDIR"

xz -T 0 -f "$OUTDIR/netbsd-rootfs.bin"
echo "Rootfs written to $OUTDIR/netbsd-rootfs.bin.xz"
