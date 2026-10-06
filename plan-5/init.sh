#!/bin/sh
set -eu

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys

# Export standard system PATH and cowsay path
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export COWPATH=/usr/share/cows

echo ""
echo "=== Running Cowsay in Firecracker MicroVM ==="
echo ""

if [ -x /usr/bin/cowsay ]; then
    /usr/bin/cowsay "Firecracker microVM running official Alpine cowsay package!"
    echo ""
    /usr/bin/cowsay -f tux "Tux says: booted under 1 second on KVM!"
else
    echo "Error: /usr/bin/cowsay not found"
fi

echo ""
echo "=== Execution completed, halting microVM ==="
reboot -f
