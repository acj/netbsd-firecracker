#!/bin/sh
#
# Local smoke test: boot the built kernel + rootfs under Firecracker and wait
# for sshd. Mirrors what the GitHub action does. Requires /dev/kvm and root
# (for the tap device). Run the three build scripts first.

set -eu

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/out"
WORKDIR="$BASEDIR/work"

KERNEL="$OUTDIR/netbsd-kern.bin"
ROOTFS_XZ="$OUTDIR/netbsd-rootfs.bin.xz"
FIRECRACKER="$OUTDIR/firecracker"

for f in "$KERNEL" "$ROOTFS_XZ" "$FIRECRACKER" "$OUTDIR/netbsd.id_rsa"; do
    [ -e "$f" ] || { echo "error: $f missing; run the build scripts first" >&2; exit 1; }
done

# Work on a copy of the rootfs so the pristine artifact isn't dirtied.
ROOTFS="$WORKDIR/test-rootfs.bin"
xz -dkc "$ROOTFS_XZ" > "$ROOTFS"
# Exercise the resize_root path like the action does.
truncate -s 4G "$ROOTFS"

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
GUEST_IP="172.16.0.2"
FC_MAC="06:00:AC:10:00:02"

ip link del "$TAP_DEV" 2>/dev/null || true
ip tuntap add dev "$TAP_DEV" mode tap
ip addr add "$TAP_IP/24" dev "$TAP_DEV"
ip link set dev "$TAP_DEV" up

cat > "$WORKDIR/vmconfig.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$KERNEL",
    "boot_args": "console=com root=ld0a"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$ROOTFS",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "$FC_MAC",
      "host_dev_name": "$TAP_DEV"
    }
  ],
  "entropy": {},
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 1024,
    "smt": false
  }
}
EOF

rm -f /tmp/netbsd-fc-test.socket
"$FIRECRACKER" --no-api --config-file "$WORKDIR/vmconfig.json" &
fc_pid=$!
trap 'kill $fc_pid 2>/dev/null || true' EXIT

echo "Waiting for sshd at $GUEST_IP ..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=1 -i "$OUTDIR/netbsd.id_rsa" \
           "root@$GUEST_IP" 'uname -a && df -h / && /sbin/sysctl -n hw.ncpu && which rsync'; then
        echo "✅ smoke test passed"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$OUTDIR/netbsd.id_rsa" "root@$GUEST_IP" /sbin/reboot || true
        # Firecracker exits when the guest reboots; give it a moment but
        # never hang here — the EXIT trap kills any leftover process.
        for i in $(seq 1 30); do
            kill -0 "$fc_pid" 2>/dev/null || break
            sleep 1
        done
        exit 0
    fi
    sleep 1
done

echo "❌ VM did not come up" >&2
exit 1
