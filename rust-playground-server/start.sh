#!/usr/bin/env bash
# Start the Firecracker-backed Rust Playground HTTP server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure base assets and toolchain rootfs are built
"${SCRIPT_DIR}/setup.sh"

# Check /dev/kvm accessibility
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Warning: /dev/kvm is not read/writable by user $USER."
    echo "Run setup to configure permissions:"
    echo "  sudo ${SCRIPT_DIR}/setup.sh"
    echo ""
fi

# Run server from repo root so relative asset paths resolve consistently
cd "${REPO_ROOT}"
export REPO_ROOT="${REPO_ROOT}"

echo "Starting Rust Playground Server on http://localhost:${PORT:-3000}..."
exec cargo run --release --manifest-path "${SCRIPT_DIR}/Cargo.toml" "$@"
