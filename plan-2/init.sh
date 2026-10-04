#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
echo "hello, world!"
reboot -f
