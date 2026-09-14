# Run NetBSD in a Firecracker VM

This repository contains the scripts needed to boot NetBSD inside of a Firecracker VM, with an eye towards running NetBSD in GitHub Actions.

## Getting started

If you want to run NetBSD in GitHub Actions, please have a look at [netbsd-firecracker-action](https://github.com/acj/netbsd-firecracker-action).

You probably won't need to use this repository directly unless you need to make changes to the base image.

## Current status

- [X] Supports NetBSD 11+ and Firecracker 1.16.1
- [X] Supports Intel and AMD CPUs
- [X] Boots \~instantly in GitHub Actions, excluding download and configuration time

## Limitations

- NetBSD 11+ because we need recent Firecracker-related changes
- x86_64 only due to the need for PVH direct boot and lack of nested virtualization support in the GitHub Actions runners (an Azure limitation)

## Contributing

Please be kind. We're all trying to do our best.

If you're having trouble and are confident that it's related to the base images, then please open
an issue. If you'd like to suggest an improvement, please open a PR.

## License

Apache 2.0
