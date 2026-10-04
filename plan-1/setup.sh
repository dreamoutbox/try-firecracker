#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
ARCH="$(uname -m)"

mkdir -p "${ASSETS_DIR}"

# Verify required host utilities
for cmd in curl wget truncate mkfs.ext4 unsquashfs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required dependency '$cmd'. Please install it first." >&2
        exit 1
    fi
done

# Check KVM availability
if [ ! -e /dev/kvm ]; then
    echo "Warning: /dev/kvm device node does not exist. Ensure KVM kernel module is loaded." >&2
elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Notice: /dev/kvm is not writable by user '$USER'. Running Firecracker will require sudo or kvm group membership."
fi

# Download Firecracker binary
if [ ! -x "${ASSETS_DIR}/firecracker" ]; then
    echo "Fetching latest Firecracker binary for ${ARCH}..."
    RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
    LATEST="$(basename "$(curl -fsSLI -o /dev/null -w "%{url_effective}" "${RELEASE_URL}/latest")")"
    TMP_DIR="$(mktemp -d)"
    curl -fsSL "${RELEASE_URL}/download/${LATEST}/firecracker-${LATEST}-${ARCH}.tgz" | tar -xz -C "${TMP_DIR}"
    mv "${TMP_DIR}/release-${LATEST}-${ARCH}/firecracker-${LATEST}-${ARCH}" "${ASSETS_DIR}/firecracker"
    chmod +x "${ASSETS_DIR}/firecracker"
    rm -rf "${TMP_DIR}"
fi

# Download Linux kernel binary from Firecracker CI
KERNEL_FILE="$(find "${ASSETS_DIR}" -maxdepth 1 -name 'vmlinux-*' | head -n 1 || true)"
if [ -z "${KERNEL_FILE}" ] || [ ! -f "${KERNEL_FILE}" ]; then
    echo "Fetching latest kernel image from Firecracker CI S3..."
    S3="https://s3.amazonaws.com/spec.ccfc.min"
    CI_PREFIX="$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
        | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
        | sort | tail -n 1)"
    KERNEL_KEY="$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/vmlinux-" \
        | grep -oP "(?<=<Key>)(${CI_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
        | sort -V | tail -n 1)"
    wget -q --show-progress -O "${ASSETS_DIR}/$(basename "${KERNEL_KEY}")" "$S3/${KERNEL_KEY}"
    KERNEL_FILE="${ASSETS_DIR}/$(basename "${KERNEL_KEY}")"
fi

# Download rootfs squashfs and build ext4 image
if [ ! -f "${ASSETS_DIR}/ubuntu.ext4" ]; then
    if [ ! -f "${ASSETS_DIR}/ubuntu.squashfs.upstream" ]; then
        echo "Fetching Ubuntu squashfs rootfs from Firecracker CI S3..."
        S3="https://s3.amazonaws.com/spec.ccfc.min"
        CI_PREFIX="$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
            | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
            | sort | tail -n 1)"
        ROOTFS_KEY="$(curl -fsSL "$S3?list-type=2&prefix=${CI_PREFIX}${ARCH}/ubuntu-" \
            | grep -oP "(?<=<Key>)(${CI_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
            | sort -V | tail -n 1)"
        wget -q --show-progress -O "${ASSETS_DIR}/ubuntu.squashfs.upstream" "$S3/${ROOTFS_KEY}"
    fi

    if [ ! -d "${ASSETS_DIR}/squashfs-root" ]; then
        echo "Unpacking rootfs squashfs..."
        unsquashfs -q -d "${ASSETS_DIR}/squashfs-root" "${ASSETS_DIR}/ubuntu.squashfs.upstream"
    fi

    INIT_SRC="${SCRIPT_DIR}/hello-init.sh"
    if [ ! -f "${INIT_SRC}" ]; then
        cat <<'INIT_EOF' > "${INIT_SRC}"
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "Hello, World!"

echo o > /proc/sysrq-trigger
INIT_EOF
        chmod +x "${INIT_SRC}"
    fi

    cp "${INIT_SRC}" "${ASSETS_DIR}/squashfs-root/hello-init.sh"
    chmod +x "${ASSETS_DIR}/squashfs-root/hello-init.sh"

    echo "Building ubuntu.ext4 filesystem image..."
    truncate -s 512M "${ASSETS_DIR}/ubuntu.ext4"
    mkfs.ext4 -d "${ASSETS_DIR}/squashfs-root" -F "${ASSETS_DIR}/ubuntu.ext4" >/dev/null 2>&1
    e2fsck -fn "${ASSETS_DIR}/ubuntu.ext4" >/dev/null 2>&1 || true
fi

echo "Setup complete. MicroVM artifacts ready:"
echo "  Firecracker : ${ASSETS_DIR}/firecracker"
echo "  Kernel      : ${KERNEL_FILE}"
echo "  Rootfs      : ${ASSETS_DIR}/ubuntu.ext4"
