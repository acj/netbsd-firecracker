#!/bin/sh

set -eu

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

# base + etc are enough for a basic CI runner. We can add comp if a compiler is needed
for set in base etc; do
    tarball="$WORKDIR/$set.tar.xz"
    if [ ! -f "$tarball" ]; then
        echo "Fetching $set.tar.xz ..."
        curl -fL -o "$tarball" \
            "$NETBSD_MIRROR/NetBSD-$NETBSD_RELEASE/$MACHINE/binary/sets/$set.tar.xz"
    fi
    tar -xJpf "$tarball" -C "$ROOTDIR"
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

PKGS="${PKGS:-${RSYNC_PKGS:-rsync}}"

SUMMARY="$WORKDIR/pkg_summary.txt"
if [ ! -f "$SUMMARY" ]; then
    echo "Fetching pkg_summary ..."
    curl -fL -o "$WORKDIR/pkg_summary.bz2" "$PKGSRC_MIRROR/pkg_summary.bz2"
    bzcat "$WORKDIR/pkg_summary.bz2" > "$SUMMARY"
fi

# Flatten pkg_summary into "base<TAB>filename<TAB>dep-bases" rows, keeping the
# highest version when a base appears more than once (e.g. bash 2.05 vs 5.3, so
# we don't drag in readline). DEPENDS patterns like "popt>=1.16nb1" or
# "bash-[0-9]*" are reduced to their bare package base.
PKGMAP="$WORKDIR/pkgmap.tsv"
LC_ALL=C awk 'BEGIN{RS="";FS="\n"}
{
    name=""; file=""; deps=""
    for (i=1;i<=NF;i++) {
        if      ($i ~ /^PKGNAME=/)   name=substr($i,9)
        else if ($i ~ /^FILE_NAME=/) file=substr($i,11)
        else if ($i ~ /^DEPENDS=/) {
            d=substr($i,9)
            sub(/[<>=].*$/,"",d); sub(/-\[.*$/,"",d); sub(/-[0-9].*$/,"",d)
            deps=(deps==""?d:deps" "d)
        }
    }
    if (name=="" || file=="") next
    base=name
    if (match(base,/-[0-9][^-]*$/)) base=substr(base,1,RSTART-1)
    print base"\t"name"\t"file"\t"deps
}' "$SUMMARY" \
    | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2V \
    | LC_ALL=C awk -F'\t' '{keep[$1]=$3"\t"$4} END{for(b in keep) print b"\t"keep[b]}' \
    > "$PKGMAP"

# Breadth-first transitive closure of PKGS over the dependency map
resolve_pkgs() {
    seen=" "; queue="$*"; out=""
    while [ -n "$queue" ]; do
        set -- $queue; base=$1; shift; queue="$*"
        case "$seen" in *" $base "*) continue ;; esac
        seen="$seen$base "
        row="$(LC_ALL=C awk -F'\t' -v b="$base" '$1==b{print;exit}' "$PKGMAP")"
        [ -n "$row" ] || { echo "error: cannot resolve package '$base' in pkg_summary" >&2; exit 1; }
        out="$out $(printf '%s' "$row" | cut -f2)"
        queue="$queue $(printf '%s' "$row" | cut -f3)"
    done
    printf '%s\n' $out
}

PKGFILES="$(resolve_pkgs $PKGS)" || exit 1
mkdir -p "$ROOTDIR/usr/pkg"
for pkgfile_name in $PKGFILES; do
    pkgfile="$WORKDIR/$pkgfile_name"
    if [ ! -f "$pkgfile" ]; then
        echo "Fetching $pkgfile_name ..."
        curl -fL -o "$pkgfile" "$PKGSRC_MIRROR/$pkgfile_name"
    fi
    tar -xf "$pkgfile" -C "$ROOTDIR/usr/pkg" --exclude '+*'
done

for b in "$ROOTDIR/usr/pkg/bin/"*; do
    [ -e "$b" ] || continue
    name="$(basename "$b")"
    [ -e "$ROOTDIR/usr/bin/$name" ] || ln -sf "../pkg/bin/$name" "$ROOTDIR/usr/bin/$name"
done

"$MAKEFS" -t ffs -B le -s "$IMAGE_SIZE" -o density=8192 \
    "$OUTDIR/netbsd-rootfs.bin" "$ROOTDIR"

xz -T 0 -f "$OUTDIR/netbsd-rootfs.bin"
echo "Rootfs written to $OUTDIR/netbsd-rootfs.bin.xz"
