#!/bin/bash
# Boot a Firecracker microVM via its REST API.
# Usage: ./scripts/boot.sh <firecracker-bin> <kernel> <rootfs>
set -euo pipefail

FC="${1:?Usage: $0 <firecracker-bin> <kernel> <rootfs>}"
KERNEL="${2:?missing kernel path}"
ROOTFS="${3:?missing rootfs path}"
SOCKET=/tmp/firecracker-hello.socket

# Use absolute paths — Firecracker resolves paths relative to its cwd.
FC=$(realpath "$FC")
KERNEL=$(realpath "$KERNEL")
ROOTFS=$(realpath "$ROOTFS")

rm -f "$SOCKET"

# Start Firecracker; serial console output comes to this terminal's stdout.
"$FC" --api-sock "$SOCKET" &
FC_PID=$!

# Wait for the socket to appear.
for i in $(seq 10); do
    [ -S "$SOCKET" ] && break
    sleep 0.1
done
[ -S "$SOCKET" ] || { echo "ERROR: socket never appeared"; kill "$FC_PID"; exit 1; }

# Helper: PUT a JSON payload to a Firecracker API endpoint.
api() {
    curl -s --unix-socket "$SOCKET" \
        -X PUT "http://localhost/$1" \
        -H "Content-Type: application/json" \
        -d "$2"
}

# Boot source: pass our custom init instead of systemd.
api boot-source "$(cat <<EOF
{
    "kernel_image_path": "$KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off init=/hello-init.sh"
}
EOF
)"

# Root drive.
api drives/rootfs "$(cat <<EOF
{
    "drive_id":       "rootfs",
    "path_on_host":   "$ROOTFS",
    "is_root_device": true,
    "is_read_only":   false
}
EOF
)"

# Machine config: 1 vCPU, 128 MiB RAM.
api machine-config '{"vcpu_count": 1, "mem_size_mib": 128}'

# Boot the VM.
api actions '{"action_type": "InstanceStart"}'

wait "$FC_PID"
