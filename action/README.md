# Run NetBSD in a Firecracker VM

> **Status: sketch.** This directory is the seed for a standalone
> `netbsd-firecracker-action` repository, mirroring
> [freebsd-firecracker-action](https://github.com/acj/freebsd-firecracker-action).
> To extract it: copy this directory to the root of a new repo (moving
> `.github/` with it), publish a `v0.1.0` release of
> [netbsd-firecracker](https://github.com/acj/netbsd-firecracker) so the
> default artifact URLs resolve, and tag the action.

This GitHub Action launches a Firecracker VM running NetBSD. The MICROVM
kernel boots in well under a second; the VM is typically reachable over ssh
in a few seconds.

## Getting started

```yaml
- name: Launch Firecracker VM
  uses: acj/netbsd-firecracker-action@v0.1.0
  with:
    run-in-vm: |
      echo "Hello from inside the VM!"
```

## How it works

This action uses a NetBSD kernel, rootfs, and Firecracker binary from
[netbsd-firecracker](https://github.com/acj/netbsd-firecracker). The kernel
is a stock NetBSD MICROVM build (PVH boot, virtio-mmio devices, no PCI/ACPI)
with the root device pinned for Firecracker; no patches to the NetBSD tree
are required.

By default the action:

1. downloads the kernel, rootfs, and Firecracker binary,
2. grows the rootfs image to `disk-size` and boots the VM behind a NAT'd
   tap device (the guest derives its IP, `172.16.0.2`, from its MAC),
3. rsyncs your workspace into the VM (`pre-run`),
4. runs your `run-in-vm` script over ssh as root, propagating its exit code,
5. rsyncs the VM's `/root` back into the workspace (`post-run`), and
6. shuts the VM down.

### NetBSD-specific behavior

- **First-boot resize reboot.** When `disk-size` is larger than the shipped
  image, the guest grows its root filesystem on first boot and immediately
  reboots (NetBSD cannot adopt a grown filesystem on a live mount).
  Firecracker reports a guest reboot as a shutdown, so the action expects one
  VM exit during startup and relaunches automatically. You don't need to do
  anything, but budget one extra boot (~2s) when growing the disk.
- **PATH.** NetBSD's non-interactive ssh sessions don't have `/sbin` or
  `/usr/sbin` in `PATH`. The action runs your `run-in-vm` script with a full
  system PATH (`/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin:...`),
  so `sysctl`, `ifconfig`, etc. work unqualified. If you ssh into the VM
  yourself from `pre-run`/`post-run` scripts, use absolute paths.
- **Clock.** The microVM has no RTC. The action copies the host's clock into
  the guest right after boot so TLS and build timestamps behave.

## Supported inputs

### `pre-run`: Run commands after the VM starts

Runs **on the host** after the VM is up. The default rsyncs the workspace
into the VM. The `firecracker` ssh host alias is configured for you.

```yaml
- uses: acj/netbsd-firecracker-action@v0.1.0
  with:
    pre-run: |
      echo "Hello from outside the VM!"
    run-in-vm: ...
```

### `run-in-vm`: Run commands inside the VM

Runs **inside the VM** as root, with `sh -e`. Its exit code becomes the
step's exit code.

```yaml
- uses: acj/netbsd-firecracker-action@v0.1.0
  with:
    run-in-vm: |
      uname -a
      make && make test
```

### `post-run`: Run commands outside the VM before it shuts down

Runs **on the host** after `run-in-vm` exits (only on success, unless
`continue-on-error` is set). The default rsyncs the VM's `/root` back into
the workspace.

### `checkout`

Default: `true`

Check out the repository so the default `pre-run` can copy it into the VM.
Set to `false` if your workflow already ran `actions/checkout` or you don't
need the repo inside the VM.

### `continue-on-error`

Default: `false`

Run `post-run` (and copy artifacts out of the VM) even if `run-in-vm` failed.
The step still fails with the script's exit code.

### `disk-size`

Default: `2G`

Size to grow the VM's disk to, in units recognized by
[truncate(1)](https://linux.die.net/man/1/truncate). Sizes larger than the
shipped image trigger the first-boot resize reboot described above.

### `vcpu-count`

Default: `auto`

Number of vCPUs to expose to the VM. `auto` matches the host's logical core
count.

### `verbose`

Default: `false`

Print host diagnostics and stream the Firecracker log (which carries the
guest console) to the job log.

### `kernel-url`, `rootfs-url`, `firecracker-url`, `ssh-public-key-url`, `ssh-private-key-url`

Override where the boot artifacts come from. Defaults point at a
[netbsd-firecracker release](https://github.com/acj/netbsd-firecracker/releases).
Note that the published ssh keypair is, by definition, public — the VM is
only reachable from the runner via the tap device, but don't expose it to
anything else.

## Test coverage

`.github/workflows/test.yml` exercises the action on every push/PR and
weekly (to catch runner-image and artifact rot), mirroring
freebsd-firecracker-action's suite:

- `pre-run` / `post-run` execute, on the host, as a non-root user
- `run-in-vm` executes in the guest (output copied back out), handles
  single quotes, and can call `/sbin` tools unqualified
- explicit and `auto` `vcpu-count` are honored inside the guest
- `disk-size: 4G` grows the root filesystem (verified both by writing 3.5G
  into it and by `df`), exercising the resize-reboot relaunch path
- the default `disk-size` boots without a resize reboot
- a failing `run-in-vm` script fails the step with its exit code
- the guest can reach the internet through the runner's NAT
