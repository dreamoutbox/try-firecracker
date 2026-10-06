# Plan 5: Alpine MicroVM with Package Management (cowsay via apk)

This POC implements and proves Section 5 of the tutorial [try-firecracker-2-apk-add-cowsay.md](../blog/try-firecracker-2-apk-add-cowsay.md).

## Overview

- **Offline Package Management**: Uses `apk.static` to bootstrap distribution packages (`cowsay` and `perl` runtime) into an unprivileged ext4 rootfs image without root or Docker.
- **Fast Execution**: Boots the ext4 rootfs directly in Firecracker with AWS CI `vmlinux` kernel.
- **Guest Execution**: Runs `/usr/bin/cowsay` and `/usr/bin/cowsay -f tux` inside `/init` as PID 1, cleanly halting with `reboot -f`.

## Directory Structure

- `setup.sh`: Downloads dependencies, unpacks Alpine minirootfs, installs `cowsay` using `apk.static`, and creates `assets/alpine-cowsay.ext4` (128 MB).
- `init.sh`: Guest PID 1 script that mounts virtual filesystems, runs `cowsay`, and triggers reboot.
- `vm_config.json`: Firecracker microVM configuration (1 vCPU, 128 MiB RAM, `alpine-cowsay.ext4`).
- `run.sh`: Wrapper script that ensures setup is complete, validates `/dev/kvm` permissions, and boots Firecracker.

## How to Run

```bash
# 1. Setup artifacts (automated via run.sh, or executed directly)
./plan-5/setup.sh

# 2. Boot the MicroVM and observe the cowsay output
./plan-5/run.sh
```
