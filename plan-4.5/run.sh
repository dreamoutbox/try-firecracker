#!/usr/bin/env bash
# Run Plan 4.5 Firecracker microVM to fetch and compile Rust crates inside guest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/vm_config.json"
FC_BIN="${REPO_ROOT}/assets/firecracker"

# 1. Ensure rootfs and dependencies are built
"${SCRIPT_DIR}/setup.sh"

# 2. Ensure host TAP device (tap1) and NAT routing are configured
"${SCRIPT_DIR}/net-setup.sh"

# 3. Check /dev/kvm access
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Notice: /dev/kvm is not writable by current user."
        echo "Attempting to run with sudo..."
        exec sudo "$0" "$@"
    fi
fi

# 4. Run from REPO_ROOT so relative paths in vm_config.json resolve consistently
cd "${REPO_ROOT}"

REL_CONFIG="$(realpath --relative-to="${REPO_ROOT}" "${CONFIG_FILE}")"

exec "${FC_BIN}" --no-api --config-file "${REL_CONFIG}" "$@"
