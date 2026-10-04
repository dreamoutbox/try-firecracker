#!/bin/sh
set -eu

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /root

# Set standard environment for cargo and rustc
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root
export CARGO_HOME=/tmp/.cargo
mkdir -p "${CARGO_HOME}"

# Prepare workspace mount point (pre-created during image build)
mkdir -p /workspace 2>/dev/null || true

# Wait for virtio-blk block device /dev/vdb
for _ in 1 2 3 4 5; do
    if [ -b /dev/vdb ]; then
        break
    fi
    sleep 0.05
done

echo "=== PLAYGROUND_EXEC_START ==="
if ! mount /dev/vdb /workspace 2>&1; then
    echo "Error: failed to mount workspace drive /dev/vdb"
else
    cd /workspace
    if cargo build --offline --release 2>&1; then
        if [ -x ./target/release/user_code ]; then
            ./target/release/user_code 2>&1 || true
        else
            echo "Error: user_code binary not found or not executable"
        fi
    else
        echo "=== COMPILATION_FAILED ==="
    fi
fi
echo "=== PLAYGROUND_EXEC_END ==="

reboot -f
