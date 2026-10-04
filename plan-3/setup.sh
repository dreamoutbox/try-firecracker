#!/usr/bin/env bash
# Setup artifacts and environment for Plan 3 (Rust Playground MVP + Firecracker).
# Installs Alpine + Rust toolchain into ext4 rootfs using apk.static without root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
ARCH="$(uname -m)"
ALPINE_VERSION="3.22.0"
TARGET_USER="${SUDO_USER:-$USER}"

mkdir -p "${ASSETS_DIR}"

# Helper: run command with elevated privileges only if needed
run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Helper: ensure required host utilities; install via apt if missing
ensure_dependencies() {
    local missing_pkgs=()
    for cmd in curl truncate mkfs.ext4 tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                mkfs.ext4) missing_pkgs+=("e2fsprogs") ;;
                truncate) missing_pkgs+=("coreutils") ;;
                *) missing_pkgs+=("$cmd") ;;
            esac
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "Installing missing packages with sudo: ${missing_pkgs[*]}..."
            run_privileged apt-get update -qq
            run_privileged apt-get install -y -qq "${missing_pkgs[@]}"
        else
            echo "Error: missing tools (${missing_pkgs[*]}); please install them." >&2
            exit 1
        fi
    fi
}

# Helper: ensure /dev/kvm permissions and access
ensure_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "Attempting to load KVM module..."
        run_privileged modprobe kvm || true
        if grep -q "vmx" /proc/cpuinfo; then
            run_privileged modprobe kvm_intel || true
        elif grep -q "svm" /proc/cpuinfo; then
            run_privileged modprobe kvm_amd || true
        fi
    fi

    if [ ! -e /dev/kvm ]; then
        echo "Warning: /dev/kvm not found. Ensure nested virtualization is enabled on host." >&2
        return 0
    fi

    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "Configuring /dev/kvm permissions (0666)..."
        run_privileged chmod 666 /dev/kvm

        if getent group kvm >/dev/null 2>&1; then
            run_privileged usermod -aG kvm "${TARGET_USER}" || true
        fi

        if [ -d /etc/udev/rules.d ] && [ ! -f /etc/udev/rules.d/99-kvm.rules ]; then
            echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' | run_privileged tee /etc/udev/rules.d/99-kvm.rules >/dev/null
            run_privileged udevadm control --reload-rules >/dev/null 2>&1 || true
            run_privileged udevadm trigger --name-match=kvm >/dev/null 2>&1 || true
        fi
    fi
}

# Helper: ensure Firecracker binary exists
ensure_firecracker() {
    local fc_bin="${ASSETS_DIR}/firecracker"
    if [ ! -x "${fc_bin}" ]; then
        echo "Fetching latest Firecracker binary for ${ARCH}..."
        local release_url="https://github.com/firecracker-microvm/firecracker/releases"
        local latest
        latest="$(basename "$(curl -fsSLI -o /dev/null -w "%{url_effective}" "${release_url}/latest")")"
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        curl -fsSL "${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz" | tar -xz -C "${tmp_dir}"
        mv "${tmp_dir}/release-${latest}-${ARCH}/firecracker-${latest}-${ARCH}" "${fc_bin}"
        chmod +x "${fc_bin}"
        rm -rf "${tmp_dir}"
    fi
}

# Helper: ensure kernel exists and assets/vmlinux symlink points to it
ensure_kernel() {
    local kernel_file
    kernel_file="$(find "${ASSETS_DIR}" -maxdepth 1 -name 'vmlinux-*' | head -n 1 || true)"
    if [ -z "${kernel_file}" ] || [ ! -f "${kernel_file}" ]; then
        echo "Fetching kernel image from Firecracker CI S3..."
        local s3="https://s3.amazonaws.com/spec.ccfc.min"
        local ci_prefix
        ci_prefix="$(curl -fsSL "$s3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
            | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
            | sort | tail -n 1)"
        local kernel_key
        kernel_key="$(curl -fsSL "$s3?list-type=2&prefix=${ci_prefix}${ARCH}/vmlinux-" \
            | grep -oP "(?<=<Key>)(${ci_prefix}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
            | sort -V | tail -n 1)"
        wget -q --show-progress -O "${ASSETS_DIR}/$(basename "${kernel_key}")" "$s3/${kernel_key}"
        kernel_file="${ASSETS_DIR}/$(basename "${kernel_key}")"
    fi

    local kernel_name
    kernel_name="$(basename "${kernel_file}")"
    ln -sfn "${kernel_name}" "${ASSETS_DIR}/vmlinux"
}

# Helper: ensure apk.static binary exists in assets
ensure_apk_static() {
    local apk_bin="${ASSETS_DIR}/apk.static"
    if [ -x "${apk_bin}" ]; then
        return 0
    fi

    echo "Fetching apk.static for ${ARCH}..."
    local alpine_repo="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH}"
    local apk_pkg
    apk_pkg="$(curl -fsSL "${alpine_repo}/" | grep -o 'apk-tools-static-[0-9][^"]*\.apk' | head -n 1 || true)"
    if [ -z "${apk_pkg}" ]; then
        apk_pkg="apk-tools-static-3.0.8-r0.apk"
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    curl -fsSL "${alpine_repo}/${apk_pkg}" -o "${tmp_dir}/pkg.apk"
    tar -xf "${tmp_dir}/pkg.apk" -C "${tmp_dir}"
    mv "${tmp_dir}/sbin/apk.static" "${apk_bin}"
    chmod +x "${apk_bin}"
    rm -rf "${tmp_dir}"
}

# Helper: build Alpine rootfs with baked-in Rust toolchain and rust_example source
ensure_rust_playground_rootfs() {
    local rootfs_img="${ASSETS_DIR}/rust-playground.ext4"
    local rust_src="${SCRIPT_DIR}/rust_example/src/main.rs"
    local cargo_toml="${SCRIPT_DIR}/rust_example/Cargo.toml"
    local init_script="${SCRIPT_DIR}/init.sh"

    # Skip rebuild if image already exists and is newer than source and init script
    if [ -f "${rootfs_img}" ] && \
       [ "${rootfs_img}" -nt "${rust_src}" ] && \
       [ "${rootfs_img}" -nt "${cargo_toml}" ] && \
       [ "${rootfs_img}" -nt "${init_script}" ]; then
        echo "Rootfs ${rootfs_img} is up-to-date."
        return 0
    fi

    ensure_apk_static

    local tarball="${ASSETS_DIR}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
    if [ ! -f "${tarball}" ]; then
        echo "Downloading Alpine minirootfs ${ALPINE_VERSION}..."
        local download_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
        curl -fsSL "${download_url}" -o "${tarball}"
    fi

    local extract_dir="${ASSETS_DIR}/rust-playground-rootfs"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    echo "Extracting Alpine minirootfs..."
    tar -xzf "${tarball}" -C "${extract_dir}"

    echo "Installing Rust toolchain into rootfs using apk.static..."
    "${ASSETS_DIR}/apk.static" \
        --root "${extract_dir}" \
        --no-progress \
        add rust cargo

    echo "Installing guest /init..."
    cp "${init_script}" "${extract_dir}/init"
    chmod +x "${extract_dir}/init"

    echo "Installing /rust_example project into rootfs..."
    mkdir -p "${extract_dir}/rust_example"
    cp "${cargo_toml}" "${extract_dir}/rust_example/"
    if [ -f "${SCRIPT_DIR}/rust_example/Cargo.lock" ]; then
        cp "${SCRIPT_DIR}/rust_example/Cargo.lock" "${extract_dir}/rust_example/"
    fi
    cp -r "${SCRIPT_DIR}/rust_example/src" "${extract_dir}/rust_example/"

    echo "Building ${rootfs_img} (1GB ext4)..."
    truncate -s 1G "${rootfs_img}"
    mkfs.ext4 -q -F -d "${extract_dir}" "${rootfs_img}"

    # Clean up extraction directory to conserve disk space
    rm -rf "${extract_dir}"
}

# Helper: preserve non-root file ownership if script was run under sudo
fix_ownership() {
    if [ -n "${SUDO_USER:-}" ] && [ "$EUID" -eq 0 ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${ASSETS_DIR}" 2>/dev/null || true
    fi
}

main() {
    ensure_dependencies
    ensure_kvm
    ensure_firecracker
    ensure_kernel
    ensure_rust_playground_rootfs
    fix_ownership

    echo "Plan 3 setup complete:"
    echo "  Firecracker : assets/firecracker"
    echo "  Kernel      : assets/vmlinux -> $(readlink "${ASSETS_DIR}/vmlinux")"
    echo "  Rootfs      : assets/rust-playground.ext4"
}

main "$@"
