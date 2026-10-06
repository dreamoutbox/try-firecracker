#!/bin/sh
# Minimal init: runs inside the Firecracker microVM instead of systemd.
# Mounts essential virtual filesystems, prints hello, then powers off.
set -eu

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo ""
echo "=== Firecracker Plan 1 MicroVM ==="
echo "Hello, World!"
echo ""

# Power off microVM; reboot -f or sysrq 'o' works with reboot=k in kernel boot args
reboot -f 2>/dev/null || echo o > /proc/sysrq-trigger
