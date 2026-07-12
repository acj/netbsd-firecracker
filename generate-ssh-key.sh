#!/bin/sh

set -eu

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/out"
mkdir -p "$OUTDIR"

rm -f "$OUTDIR/netbsd.id_rsa" "$OUTDIR/netbsd.id_rsa.pub"
ssh-keygen -t rsa -b 4096 -N "" -C "netbsd-firecracker" -f "$OUTDIR/netbsd.id_rsa"
