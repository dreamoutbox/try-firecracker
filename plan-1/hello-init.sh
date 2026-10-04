#!/bin/sh
# Minimal init: runs inside the Firecracker microVM instead of systemd.
# Mounts essential virtual filesystems, prints hello, then powers off.

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "Hello, World!"

# sysrq 'o' = power off; works with reboot=k in kernel boot args
echo o > /proc/sysrq-trigger
