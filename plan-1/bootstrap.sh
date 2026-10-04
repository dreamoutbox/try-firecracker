#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
BOOT_SCRIPT="${SCRIPT_DIR}/boot.sh"

# Run setup to verify or download artifacts
"${SCRIPT_DIR}/setup.sh"

FC_BIN="${ASSETS_DIR}/firecracker"
KERNEL_BIN="$(find "${ASSETS_DIR}" -maxdepth 1 -name 'vmlinux-*' | head -n 1 || true)"
ROOTFS_IMG="${ASSETS_DIR}/ubuntu.ext4"

if [ ! -x "${FC_BIN}" ]; then
    echo "Error: Firecracker binary not found or not executable at ${FC_BIN}" >&2
    exit 1
fi

if [ -z "${KERNEL_BIN}" ] || [ ! -f "${KERNEL_BIN}" ]; then
    echo "Error: Kernel image not found in ${ASSETS_DIR}" >&2
    exit 1
fi

if [ ! -f "${ROOTFS_IMG}" ]; then
    echo "Error: Rootfs image not found at ${ROOTFS_IMG}" >&2
    exit 1
fi

if [ ! -x "${BOOT_SCRIPT}" ]; then
    chmod +x "${BOOT_SCRIPT}"
fi

# Elevate privileges if current user cannot write to /dev/kvm
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Notice: /dev/kvm requires elevated privileges. Running with sudo..."
        exec sudo "${BOOT_SCRIPT}" "${FC_BIN}" "${KERNEL_BIN}" "${ROOTFS_IMG}"
    fi
fi

exec "${BOOT_SCRIPT}" "${FC_BIN}" "${KERNEL_BIN}" "${ROOTFS_IMG}"
