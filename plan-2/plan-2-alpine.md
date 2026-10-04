## Plan

1. Get `firecracker` and a guest kernel
2. Build an Alpine ext4 rootfs with a custom `/init`
3. Boot with a config file (no API socket needed)
4. VM prints the message and reboots, and Firecracker exits

### 1. Binaries

```bash
mkdir fc-hello && cd fc-hello
ARCH=$(uname -m)
TAG=$(curl -s https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest | grep -oP '"tag_name": "\K[^"]+')
curl -sL "https://github.com/firecracker-microvm/firecracker/releases/download/${TAG}/firecracker-${TAG}-${ARCH}.tgz" | tar xz
cp release-${TAG}-${ARCH}/firecracker-${TAG}-${ARCH} firecracker
```

Kernel: use the CI `vmlinux` from the snippet in `docs/getting-started.md`. It has virtio-blk and ext4 built in. Save it as `./vmlinux`. A stock distro kernel usually won't work, since it needs initrd modules.

### 2. Rootfs

```bash
ALPINE=3.22.0   # any current minirootfs release works
curl -sLO "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE%.*}/releases/${ARCH}/alpine-minirootfs-${ALPINE}-${ARCH}.tar.gz"

mkdir rootfs
sudo tar -xzf alpine-minirootfs-*.tar.gz -C rootfs

sudo tee rootfs/init >/dev/null <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
echo "hello, world!"
reboot -f
EOF
sudo chmod +x rootfs/init

truncate -s 64M rootfs.ext4
sudo mkfs.ext4 -q -F -d rootfs rootfs.ext4   # populates without a loop mount
```

`reboot -f` is deliberate. If PID 1 exits, the kernel panics. Firecracker on x86 has no ACPI, so `poweroff` doesn't stop the VM, but `reboot=k` in the boot args turns a reboot into a clean VMM exit.

### 3. VM config

`vm_config.json`:
```json
{
  "boot-source": {
    "kernel_image_path": "vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 init=/init"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 128 }
}
```

### 4. Run

```bash
./firecracker --no-api --config-file vm_config.json
```

Expected: kernel boot log on the serial console, then `hello, world!`, then Firecracker exits.

To cut the noise, append `quiet loglevel=0` to `boot_args`.

### Troubleshooting

| Symptom | Cause |
|---|---|
| `/dev/kvm` permission denied | `sudo setfacl -m u:$USER:rw /dev/kvm` |
| `VFS: Unable to mount root fs` | Kernel lacks ext4 or virtio-blk built in, or the rootfs wasn't built correctly |
| Panic: `Attempted to kill init` | `/init` is missing the exec bit or the shebang is wrong |
| Hangs after the message | You used `poweroff` instead of `reboot -f`, or `reboot=k` is missing |

### Next steps
- Replace `/init` with OpenRC (`apk add openrc` via `chroot`) for a real Alpine boot
- Add a `network-interfaces` entry plus a TAP device
- Add the vsock device to run commands in the guest
