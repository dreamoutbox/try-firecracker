#!/usr/bin/env bash
# Setup artifacts and environment for Plan 2 (Alpine minirootfs + Firecracker).
# Privileged operations (package install, /dev/kvm setup) automatically use sudo.
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

    # Set permissions on /dev/kvm if not already writable
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

    # Create/update relative symlink assets/vmlinux -> vmlinux-*
    local kernel_name
    kernel_name="$(basename "${kernel_file}")"
    ln -sfn "${kernel_name}" "${ASSETS_DIR}/vmlinux"
}

# Helper: build Alpine ext4 image with custom init
ensure_alpine_rootfs() {
    local rootfs_img="${ASSETS_DIR}/alpine.ext4"
    if [ -f "${rootfs_img}" ]; then
        return 0
    fi

    local tarball="${ASSETS_DIR}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
    if [ ! -f "${tarball}" ]; then
        echo "Downloading Alpine minirootfs ${ALPINE_VERSION}..."
        local download_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
        curl -fsSL "${download_url}" -o "${tarball}"
    fi

    local extract_dir="${ASSETS_DIR}/alpine-rootfs"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    echo "Extracting Alpine minirootfs..."
    tar -xzf "${tarball}" -C "${extract_dir}"

    echo "Installing guest /init..."
    cp "${SCRIPT_DIR}/init.sh" "${extract_dir}/init"
    chmod +x "${extract_dir}/init"

    echo "Building ${rootfs_img} (64MB ext4)..."
    truncate -s 64M "${rootfs_img}"
    mkfs.ext4 -q -F -d "${extract_dir}" "${rootfs_img}"

    # Clean up extraction directory to conserve space
    rm -rf "${extract_dir}"
}

# Helper: ensure vm_config.json exists
ensure_vm_config() {
    local config_file="${SCRIPT_DIR}/vm_config.json"
    if [ ! -f "${config_file}" ]; then
        echo "Creating ${config_file}..."
        cat << 'EOF' > "${config_file}"
{
  "boot-source": {
    "kernel_image_path": "assets/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 init=/init"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "assets/alpine.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 128
  }
}
EOF
    fi
}

# Helper: preserve non-root file ownership if script was run under sudo
fix_ownership() {
    if [ -n "${SUDO_USER:-}" ] && [ "$EUID" -eq 0 ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${ASSETS_DIR}" "${SCRIPT_DIR}/vm_config.json" 2>/dev/null || true
    fi
}

main() {
    ensure_dependencies
    ensure_kvm
    ensure_firecracker
    ensure_kernel
    ensure_alpine_rootfs
    ensure_vm_config
    fix_ownership

    echo "Plan 2 setup complete:"
    echo "  Firecracker : assets/firecracker"
    echo "  Kernel      : assets/vmlinux -> $(readlink "${ASSETS_DIR}/vmlinux")"
    echo "  Rootfs      : assets/alpine.ext4"
    echo "  VM Config   : plan-2/vm_config.json"
}

main "$@"
