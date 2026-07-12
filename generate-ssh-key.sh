#!/bin/sh
#
# Generate the SSH keypair baked into the rootfs and published with each
# release. Like freebsd-firecracker, the private key is intentionally public:
# the VM is a throwaway CI guest reachable only over the runner-local tap
# device, and publishing the key is what lets the action ssh in with zero
# configuration.
#
# Outputs:
#   out/netbsd.id_rsa
#   out/netbsd.id_rsa.pub

set -eu

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/out"
mkdir -p "$OUTDIR"

rm -f "$OUTDIR/netbsd.id_rsa" "$OUTDIR/netbsd.id_rsa.pub"
ssh-keygen -t rsa -b 4096 -N "" -C "netbsd-firecracker" -f "$OUTDIR/netbsd.id_rsa"
