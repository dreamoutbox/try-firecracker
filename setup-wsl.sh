#!/bin/sh
# RUN AS SUDO

sudo setfacl -m u:${USER}:rw /dev/kvm
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "OK" || echo "FAIL"
