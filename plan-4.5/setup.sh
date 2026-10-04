#!/usr/bin/env bash
# Setup artifacts and rootfs for Plan 4.5 (In-VM Cargo Crates.io Dependency Resolution).
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
    for cmd in curl truncate mkfs.ext4 tar iptables ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                mkfs.ext4) missing_pkgs+=("e2fsprogs") ;;
                truncate) missing_pkgs+=("coreutils") ;;
                ip) missing_pkgs+=("iproute2") ;;
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
    local vmlinux="${ASSETS_DIR}/vmlinux"
    if [ -e "${vmlinux}" ]; then
        return 0
    fi

    local kernel_ci="${ASSETS_DIR}/vmlinux-6.18.51"
    if [ ! -f "${kernel_ci}" ]; then
        echo "Downloading Firecracker CI kernel 6.18.51..."
        curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.11/${ARCH}/vmlinux-6.1.102" -o "${kernel_ci}"
    fi

    echo "Linking ${kernel_ci} -> ${vmlinux}..."
    ln -s "$(basename "${kernel_ci}")" "${vmlinux}"
}

# Helper: ensure apk.static is available
ensure_apk_static() {
    local apk_static="${ASSETS_DIR}/apk.static"
    if [ -x "${apk_static}" ]; then
        return 0
    fi

    echo "Fetching apk.static for Alpine package bootstrapping..."
    local apk_tools_pkg="apk-tools-static-2.14.6-r2.apk"
    local apk_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/main/${ARCH}/${apk_tools_pkg}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    curl -fsSL "${apk_url}" -o "${tmp_dir}/${apk_tools_pkg}"
    tar -xzf "${tmp_dir}/${apk_tools_pkg}" -C "${tmp_dir}" sbin/apk.static
    mv "${tmp_dir}/sbin/apk.static" "${apk_static}"
    chmod +x "${apk_static}"
    rm -rf "${tmp_dir}"
}

# Helper: assemble rootfs with Rust toolchain, CA certificates, and rust_example
ensure_cratesio_rootfs() {
    local rootfs_img="${ASSETS_DIR}/rust-cratesio.ext4"
    local rust_src="${SCRIPT_DIR}/rust_example/src/main.rs"
    local cargo_toml="${SCRIPT_DIR}/rust_example/Cargo.toml"
    local init_script="${SCRIPT_DIR}/init.sh"

    # Skip rebuild if image already exists and is newer than source files
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

    local extract_dir="${ASSETS_DIR}/rust-cratesio-rootfs"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    echo "Extracting Alpine minirootfs..."
    tar -xzf "${tarball}" -C "${extract_dir}"

    echo "Installing Rust toolchain and ca-certificates via apk.static..."
    "${ASSETS_DIR}/apk.static" \
        --root "${extract_dir}" \
        --no-progress \
        add rust cargo ca-certificates curl

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

    echo "Building ${rootfs_img} (2GB ext4)..."
    truncate -s 2G "${rootfs_img}"
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
    ensure_cratesio_rootfs
    fix_ownership

    echo "Plan 4.5 setup complete:"
    echo "  Firecracker : assets/firecracker"
    echo "  Kernel      : assets/vmlinux -> $(readlink "${ASSETS_DIR}/vmlinux")"
    echo "  Rootfs      : assets/rust-cratesio.ext4"
}

main "$@"
