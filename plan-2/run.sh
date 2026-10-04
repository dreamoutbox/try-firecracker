#!/usr/bin/env bash
# Run Plan 2 Firecracker microVM with Alpine rootfs and config file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/vm_config.json"
FC_BIN="${REPO_ROOT}/assets/firecracker"

# Ensure artifacts and config are built
"${SCRIPT_DIR}/setup.sh"

# Check /dev/kvm access
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Notice: /dev/kvm is not writable by current user."
        echo "Run setup with sudo once in your terminal:"
        echo "  sudo ${SCRIPT_DIR}/setup.sh"
        echo ""
        echo "Attempting to run with sudo..."
        exec sudo "$0" "$@"
    fi
fi

# Run from REPO_ROOT so relative paths in vm_config.json resolve consistently
cd "${REPO_ROOT}"

REL_CONFIG="$(realpath --relative-to="${REPO_ROOT}" "${CONFIG_FILE}")"

exec "${FC_BIN}" --no-api --config-file "${REL_CONFIG}" "$@"
