#!/bin/sh
#
# Assemble the NetBSD FFS root filesystem image for the Firecracker guest.
#
# Runs on a Linux host. Uses the official NetBSD binary sets (no VM bootstrap)
# and the cross toolchain's nbmakefs (built by build-kernel.sh) to create the
# image, so no loop mounts or chroots are needed. Run as root (or under
# fakeroot) so extracted file ownership is preserved.
#
# Outputs:
#   out/netbsd-rootfs.bin.xz

set -eu

NETBSD_RELEASE="${NETBSD_RELEASE:-11.0_RC5}"
NETBSD_MIRROR="${NETBSD_MIRROR:-https://cdn.netbsd.org/pub/NetBSD}"
# pkgsrc binary packages; keep the quarterly branch in sync with the release.
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

# --- Extract binary sets ------------------------------------------------------
# base + etc are enough for a CI guest; add comp if users want cc in the VM.
# Since NetBSD 10 the binary sets are published as .tar.xz (source sets and
# pkgsrc packages are still .tgz).
for set in base etc; do
    tarball="$WORKDIR/$set.tar.xz"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $set.tar.xz ..."
        curl -fL -o "$tarball" \
            "$NETBSD_MIRROR/NetBSD-$NETBSD_RELEASE/$MACHINE/binary/sets/$set.tar.xz"
    fi
    tar -xJpf "$tarball" -C "$ROOTDIR"
done

# --- Device nodes -------------------------------------------------------------
# The sets don't include /dev entries; nbmakefs can't create them from a Linux
# host either, so rely on NetBSD's init running MAKEDEV on first boot when it
# finds an empty /dev. Ship the MAKEDEV script where init expects it.
# (Alternative if this proves flaky: generate an mtree spec with the device
# nodes and pass it to nbmakefs -F.)
[ -f "$ROOTDIR/dev/MAKEDEV" ] || cp "$ROOTDIR/etc/MAKEDEV" "$ROOTDIR/dev/MAKEDEV" 2>/dev/null || true

# --- Guest configuration ------------------------------------------------------
install -m 644 "$BASEDIR/files/rc.conf" "$ROOTDIR/etc/rc.conf"
install -m 555 "$BASEDIR/files/fcnet"   "$ROOTDIR/etc/rc.d/fcnet"

# Root filesystem on the first virtio disk. Plain `rw` (no `log`): the
# resize_root rc.d script refuses to grow a WAPBL-journaled filesystem.
cat > "$ROOTDIR/etc/fstab" <<EOF
/dev/ld0a / ffs rw 1 1
EOF

# DNS inside the VM (the action NATs the guest through the runner).
cat > "$ROOTDIR/etc/resolv.conf" <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

echo "netbsd-firecracker" > "$ROOTDIR/etc/myname"

# SSH: root login with the baked-in key only.
mkdir -p "$ROOTDIR/root/.ssh"
chmod 700 "$ROOTDIR/root/.ssh"
install -m 600 "$OUTDIR/netbsd.id_rsa.pub" "$ROOTDIR/root/.ssh/authorized_keys"
cat >> "$ROOTDIR/etc/ssh/sshd_config" <<EOF

# netbsd-firecracker: key-only root login for the CI harness
PermitRootLogin prohibit-password
UseDNS no
EOF

# Entropy seed. Belt-and-suspenders with the virtio-rng device the action
# configures; see README before shipping a public image with a baked seed.
mkdir -p "$ROOTDIR/var/db"
dd if=/dev/urandom of="$ROOTDIR/var/db/entropy-file" bs=512 count=1 2>/dev/null
chmod 600 "$ROOTDIR/var/db/entropy-file"

# --- rsync from pkgsrc --------------------------------------------------------
# The default pre-run/post-run steps in the action use rsync over ssh. We can't
# run pkg_add from a Linux host, so extract the package payloads directly.
# pkgsrc binary packages are tarballs whose non-metadata contents ("+*" files
# are metadata) are rooted at the package prefix (/usr/pkg).
#
# TODO: verify the dependency closure for the pinned pkgsrc branch. For
# rsync this is typically just rsync itself (zlib/xz come from base), but
# check `pkg_info -n rsync` on a NetBSD box when pinning versions.
RSYNC_PKGS="${RSYNC_PKGS:-rsync}"
mkdir -p "$ROOTDIR/usr/pkg"
for pkg in $RSYNC_PKGS; do
    pkgfile="$WORKDIR/$pkg.tgz"
    if [ ! -f "$pkgfile" ]; then
        # Resolve the exact versioned filename from the mirror index. Anchor
        # the match to the start of the href so e.g. "openrsync-*.tgz" doesn't
        # shadow "rsync-*.tgz".
        pkgname="$(curl -fsL "$PKGSRC_MIRROR/" \
            | grep -o "href=\"${pkg}-[0-9][^\"]*\.tgz\"" \
            | sed 's/^href="//; s/"$//' | sort -V | tail -1)"
        [ -n "$pkgname" ] || { echo "error: could not resolve $pkg on $PKGSRC_MIRROR" >&2; exit 1; }
        echo "Fetching $pkgname ..."
        curl -fL -o "$pkgfile" "$PKGSRC_MIRROR/$pkgname"
    fi
    # No -z: pkgsrc packages keep the .tgz suffix but newer official builds
    # are zstd-compressed; let GNU tar detect the compression from the file.
    tar -xf "$pkgfile" -C "$ROOTDIR/usr/pkg" --exclude '+*'
done
# /usr/pkg/bin is in the default PATH, but the action invokes plain `rsync`
# over ssh (non-interactive shell); a symlink into /usr/bin avoids PATH games.
ln -sf ../pkg/bin/rsync "$ROOTDIR/usr/bin/rsync"

# --- Build the image ----------------------------------------------------------
# A bare FFS image with no disklabel: the kernel synthesizes a label where
# partition 'a' spans the whole disk, which is what root=ld0a expects, and it
# keeps spanning the disk when the action truncates the image larger (the
# resize_root hook then grows the filesystem into the new space).
"$MAKEFS" -t ffs -B le -s "$IMAGE_SIZE" -o density=8192 \
    "$OUTDIR/netbsd-rootfs.bin" "$ROOTDIR"

xz -T 0 -f "$OUTDIR/netbsd-rootfs.bin"
echo "Rootfs written to $OUTDIR/netbsd-rootfs.bin.xz"
