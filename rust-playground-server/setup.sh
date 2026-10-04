#!/usr/bin/env bash
# Setup artifacts and environment for rust-playground-server.
# Builds assets/rust-toolchain.ext4 (read-only base image with Rust toolchain and guest init).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
ARCH="$(uname -m)"
ALPINE_VERSION="3.22.0"
TARGET_USER="${SUDO_USER:-$USER}"

mkdir -p "${ASSETS_DIR}"

ensure_base_assets() {
    local fc_bin="${ASSETS_DIR}/firecracker"
    local kernel_link="${ASSETS_DIR}/vmlinux"
    local apk_bin="${ASSETS_DIR}/apk.static"

    if [ ! -x "${fc_bin}" ] || [ ! -e "${kernel_link}" ] || [ ! -x "${apk_bin}" ]; then
        echo "Base assets missing in ${ASSETS_DIR}. Running plan-3/setup.sh to provision them..."
        "${REPO_ROOT}/plan-3/setup.sh"
    fi
}

ensure_toolchain_rootfs() {
    local rootfs_img="${ASSETS_DIR}/rust-toolchain.ext4"
    local init_script="${SCRIPT_DIR}/guest-init/init.sh"

    if [ -f "${rootfs_img}" ] && [ "${rootfs_img}" -nt "${init_script}" ]; then
        echo "Toolchain rootfs ${rootfs_img} is up-to-date."
        return 0
    fi

    local tarball="${ASSETS_DIR}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
    if [ ! -f "${tarball}" ]; then
        echo "Downloading Alpine minirootfs ${ALPINE_VERSION}..."
        local download_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
        curl -fsSL "${download_url}" -o "${tarball}"
    fi

    local extract_dir="${ASSETS_DIR}/rust-toolchain-rootfs"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    echo "Extracting Alpine minirootfs..."
    tar -xzf "${tarball}" -C "${extract_dir}"

    echo "Installing Rust toolchain into toolchain rootfs using apk.static..."
    "${ASSETS_DIR}/apk.static" \
        --root "${extract_dir}" \
        --no-progress \
        add rust cargo

    echo "Installing guest /init..."
    cp "${init_script}" "${extract_dir}/init"
    chmod +x "${extract_dir}/init"

    echo "Creating /workspace mount point directory..."
    mkdir -p "${extract_dir}/workspace"

    echo "Building ${rootfs_img} (1GB ext4)..."
    truncate -s 1G "${rootfs_img}"
    mkfs.ext4 -q -F -d "${extract_dir}" "${rootfs_img}"

    rm -rf "${extract_dir}"
}

fix_ownership() {
    if [ -n "${SUDO_USER:-}" ] && [ "$EUID" -eq 0 ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${ASSETS_DIR}" 2>/dev/null || true
    fi
}

main() {
    ensure_base_assets
    ensure_toolchain_rootfs
    fix_ownership

    echo "rust-playground-server setup complete:"
    echo "  Toolchain rootfs: assets/rust-toolchain.ext4"
}

main "$@"
