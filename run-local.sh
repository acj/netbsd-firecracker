#!/bin/sh

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

ROOTFS="$WORKDIR/test-rootfs.bin"
xz -dkc "$ROOTFS_XZ" > "$ROOTFS"
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
start_firecracker() {
    "$FIRECRACKER" --no-api --config-file "$WORKDIR/vmconfig.json" &
    fc_pid=$!
}
start_firecracker
trap 'kill $fc_pid 2>/dev/null || true' EXIT

# When resize_root grows the filesystem on first boot it reboots the guest, which Firecracker
# treats as a shutdown. Allow one relaunch for that, and then treat additional exits as failures.
relaunches=1

echo "Waiting for sshd at $GUEST_IP ..."
for i in $(seq 1 60); do
    if ! kill -0 "$fc_pid" 2>/dev/null; then
        wait "$fc_pid" 2>/dev/null || true
        if [ "$relaunches" -gt 0 ]; then
            relaunches=$((relaunches - 1))
            echo "Firecracker exited (first-boot resize reboot); relaunching ..."
            start_firecracker
        else
            echo "❌ Firecracker exited unexpectedly" >&2
            exit 1
        fi
    fi
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=1 -i "$OUTDIR/netbsd.id_rsa" \
           "root@$GUEST_IP" 'uname -a && df -h / && /sbin/sysctl -n hw.ncpu && which rsync'; then
        rootkb=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$OUTDIR/netbsd.id_rsa" "root@$GUEST_IP" 'df -k /' \
            | awk 'NR==2 {print $2}')
        if [ "${rootkb:-0}" -lt 3000000 ]; then
            echo "❌ root fs is ${rootkb:-?}KB; resize_root didn't grow it" >&2
            exit 1
        fi
        echo "✅ smoke test passed"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$OUTDIR/netbsd.id_rsa" "root@$GUEST_IP" /sbin/reboot || true
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
