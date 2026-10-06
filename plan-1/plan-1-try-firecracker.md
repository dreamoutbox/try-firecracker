# Plan: Try Firecracker — Hello World MicroVM

## Goal

Boot a Firecracker microVM that automatically prints "Hello, World!" on the
serial console (ttyS0) and exits.

---

## Assumptions & Risks

- Host is Linux x86_64 (or aarch64) with KVM enabled.
- `/dev/kvm` is accessible by the current user (or `sudo` is available).
- `wget`, `curl`, `mkfs.ext4`, `unsquashfs` (squashfs-tools), and `truncate`
  are installed on the host.
- Network access to AWS S3 (Firecracker CI bucket) and GitHub is available.
- The official Firecracker CI rootfs is Ubuntu-based; we will add a minimal
  init override so the VM prints hello and shuts down automatically instead of
  waiting at a login prompt.

---

## Phases

### Phase 1: Verify Prerequisites

- **Goal**: Confirm the host can run Firecracker before downloading anything.
- **Tasks**:
  - [ ] Check KVM module is loaded: `lsmod | grep kvm`
  - [ ] Check `/dev/kvm` read/write access:
        `[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo OK || echo FAIL`
  - [ ] If FAIL: grant access via ACL or kvm group:
        `sudo setfacl -m u:${USER}:rw /dev/kvm`
  - [ ] Confirm required tools: `wget curl mkfs.ext4 unsquashfs truncate`
        (install `squashfs-tools e2fsprogs` if missing)
- **Done when**: `/dev/kvm` check prints `OK` and all tools are present.

---

### Phase 2: Download Firecracker Binary, Kernel, and Rootfs

- **Goal**: Obtain the three required artifacts from the official Firecracker CI.
- **Tasks**:
  - [ ] Create workspace directory: `mkdir -p assets && cd assets`
  - [ ] Download the latest Firecracker binary:
    ```bash
    ARCH="$(uname -m)"
    release_url="https://github.com/firecracker-microvm/firecracker/releases"
    latest=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} \
        ${release_url}/latest))
    curl -L ${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz \
        | tar -xz
    mv release-${latest}-${ARCH}/firecracker-${latest}-${ARCH} firecracker
    chmod +x firecracker
    ```
  - [ ] Download the latest CI kernel and Ubuntu rootfs squashfs:
    ```bash
    ARCH="$(uname -m)"
    S3="https://s3.amazonaws.com/spec.ccfc.min"

    CI_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
        | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
        | sort | tail -1)

    KERNEL_KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/vmlinux-" \
        | grep -oP "(?<=<Key>)(${CI_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
        | sort -V | tail -1)

    wget "$S3/${KERNEL_KEY}"

    ROOTFS_KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/ubuntu-" \
        | grep -oP "(?<=<Key>)(${CI_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
        | sort -V | tail -1)

    wget -O ubuntu.squashfs.upstream "$S3/$ROOTFS_KEY"
    ```
- **Done when**: `firecracker --version` works and both `vmlinux-*` and
  `ubuntu.squashfs.upstream` exist in `assets/`.

---

### Phase 3: Build a Custom Rootfs with Hello World Init

- **Goal**: Create an ext4 rootfs that, on first boot, runs a shell script
  printing "Hello, World!" then powers off.
- **Tasks**:
  - [ ] Unpack the squashfs: `unsquashfs ubuntu.squashfs.upstream`
  - [ ] Write `plan-1/init.sh` (the in-VM init replacement):
    ```sh
    #!/bin/sh
    # Mount essential virtual filesystems
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

    echo "Hello, World!"

    # Graceful shutdown — sends reboot=k (keyboard) signal Firecracker understands
    reboot -f 2>/dev/null || echo o > /proc/sysrq-trigger
    ```
  - [ ] Copy the script into the rootfs and register it as the init:
    ```bash
    cp plan-1/init.sh squashfs-root/init
    chmod +x squashfs-root/init
    ```
  - [ ] Pack the squashfs-root into an ext4 image:
    ```bash
    truncate -s 512M ubuntu.ext4
    mkfs.ext4 -d squashfs-root -F ubuntu.ext4
    ```
  - [ ] Verify: `e2fsck -fn ubuntu.ext4`
- **Done when**: `ubuntu.ext4` passes `e2fsck` and contains `/init`.

---

### Phase 4: Configure and Boot the MicroVM

- **Goal**: Boot the VM using Firecracker configuration file and observe "Hello, World!"
  on the console.
- **Tasks**:
  - [ ] Create `plan-1/vm_config.json`:
    ```json
    {
      "boot-source": {
        "kernel_image_path": "assets/vmlinux",
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off init=/init"
      },
      "drives": [
        {
          "drive_id": "rootfs",
          "path_on_host": "assets/ubuntu.ext4",
          "is_root_device": true,
          "is_read_only": false
        }
      ],
      "machine-config": {
        "vcpu_count": 1,
        "mem_size_mib": 128
      }
    }
    ```
  - [ ] Run using `plan-1/run.sh`:
    ```bash
    ./plan-1/run.sh
    ```
  - [ ] Observe the Linux boot sequence on stdout, then "Hello, World!", then VM exit.
- **Done when**: "Hello, World!" appears in the console output and the process
  exits cleanly.

---

## File Layout After Completion

```
try-firecracker/
├── README.md
├── assets/           # downloaded artifacts (gitignored — large binaries)
│   ├── firecracker
│   ├── vmlinux -> vmlinux-X.Y.Z
│   └── ubuntu.ext4
└── plan-1/
    ├── init.sh         # runs inside the VM
    ├── setup.sh        # downloads artifacts and builds rootfs
    ├── run.sh          # launches Firecracker microVM
    └── vm_config.json  # Firecracker VM config
```

Add to `.gitignore`:
```
assets/
squashfs-root/
*.ext4
*.squashfs*
```

