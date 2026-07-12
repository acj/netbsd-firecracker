# netbsd-firecracker

Build pipeline for the artifacts consumed by the [NetBSD Firecracker action](../netbsd/):

| Artifact | Produced by | Notes |
|---|---|---|
| `netbsd-kern.bin` | `build-kernel.sh` | NetBSD 11.x `MICROVM` kernel, raw ELF with PVH note |
| `netbsd-rootfs.bin.xz` | `build-rootfs.sh` | FFS root filesystem image built with `nbmakefs` |
| `firecracker` | `fetch-firecracker.sh` | stock upstream release binary (>= 1.12 for PVH) |
| `netbsd.id_rsa`, `netbsd.id_rsa.pub` | `generate-ssh-key.sh` | keypair baked into the rootfs and downloaded by the action |

> **Status: sketch.** This directory is intended to be extracted into its own
> repository (`netbsd-firecracker`), or to become a subdirectory of
> `freebsd-firecracker` if that repo is renamed to `bsd-firecracker`. The scripts
> encode the intended design and are annotated where behavior is unverified.

## Why this is simpler than freebsd-firecracker

`freebsd-firecracker` has to boot the official FreeBSD VM image under QEMU to build a
patched kernel and extract a rootfs. NetBSD needs none of that:

- **No kernel patches.** NetBSD 11.0's `MICROVM` kernel config targets Firecracker
  directly (PVH boot, virtio-over-MMIO via `pv(4)`, pvclock, `MPBIOS` +
  `MPTABLE_LINUX_BUG_COMPAT` for SMP without ACPI).
- **No VM bootstrap.** NetBSD's `build.sh` cross-compiles the toolchain and kernel on
  any Linux host, and the same toolchain provides `nbmakefs`, so the rootfs image can
  be assembled directly from the official binary sets — everything runs in a plain
  Linux CI job.

## Build

```sh
# 1. Cross-build toolchain + MICROVM kernel (~30-60 min the first time)
./build-kernel.sh

# 2. Generate the SSH keypair baked into the rootfs
./generate-ssh-key.sh

# 3. Assemble the rootfs image (needs root or fakeroot for file ownership)
sudo ./build-rootfs.sh

# 4. Fetch a stock Firecracker release binary
./fetch-firecracker.sh

# 5. Smoke-test locally (needs /dev/kvm)
sudo ./run-local.sh
```

`workflows/release.yml` is a sketch of the GitHub Actions release pipeline; move it to
`.github/workflows/` when this becomes its own repo.

## Design notes

### Kernel

Built from the official NetBSD source sets with `build.sh -m amd64 tools kernel=MICROVM`.
The output (`sys/arch/amd64/compile/MICROVM/netbsd`) is an ELF with the PVH entry-point
note; Firecracker >= 1.12 loads it directly. Boot args used by the action:
`console=com root=ld0a`. Firecracker appends `virtio_mmio.device=...` parameters for
each configured device, which NetBSD's `pv(4)` bus parses for device discovery.

If runner-specific quirks do turn up, add a local config that includes `MICROVM` plus
overrides (see `files/FIRECRACKER.conf`) rather than patching the tree.

### Rootfs

Assembled from the official `base.tgz` + `etc.tgz` binary sets into an FFS image with
`nbmakefs` (no loop mounts, no chroot). Guest-side configuration lives in `files/`:

- `rc.conf` — enables `sshd`, `resize_root=YES` (grows the filesystem to match the
  host-side `truncate` of the image; requires the root fs to be mounted *without*
  WAPBL logging, hence plain `rw` in fstab), and the `fcnet` script.
- `fcnet` — rc.d script that derives the guest IP from the MAC address
  (`06:00:AC:10:00:02` → `172.16.0.2`, gateway `172.16.0.1`), mirroring
  freebsd-firecracker's `fcnet-setup.sh`.
- `sshd_config` fragment — root login with the baked-in public key only.

`rsync` is installed by extracting the pkgsrc binary package payloads directly (we
can't run `pkg_add` from a Linux build host). See `build-rootfs.sh` for the caveats.

**Entropy:** NetBSD's entropy subsystem blocks consumers on an unseeded pool, which
can hang sshd at first boot in a VM. Two mitigations: the action configures
Firecracker's virtio-rng (`"entropy"` device, consumed by `viornd(4)`), and the rootfs
build writes a random seed to `/var/db/entropy-file`. Note that a seed baked into a
*published* rootfs image is shared by all users — fine for throwaway CI VMs, but the
virtio-rng device is the real fix; consider dropping the baked seed once viornd is
confirmed working.

### Firecracker

Stock upstream release. No fork, no patches. `fetch-firecracker.sh` downloads and
verifies a pinned version.

## Open items

- [ ] Pin to NetBSD 11.0 release once it ships (currently tracking an RC)
- [ ] First boot on GitHub Actions hardware (Intel and AMD runners)
- [ ] Confirm SMP brings up all vCPUs via MP tables (no ACPI in MICROVM)
- [ ] Confirm `resize_root` grows the fs when the image is truncated larger on the host
- [ ] Confirm `reboot` inside the guest terminates the Firecracker process
- [ ] Verify rsync-from-pkgsrc extraction (dependency closure, PATH)
- [ ] Boot-time measurement (target: comparable to FreeBSD's ~12s, likely much faster)
