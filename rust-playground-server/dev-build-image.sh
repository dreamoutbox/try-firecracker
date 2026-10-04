#!/usr/bin/env bash
# Build the Rust Playground Server Docker image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure base assets and toolchain rootfs are built on host
"${SCRIPT_DIR}/setup.sh"

echo "Building Docker image rust-playground-server:latest..."
docker build -f "${SCRIPT_DIR}/Dockerfile" -t rust-playground-server:latest "${REPO_ROOT}" "$@"

echo "Docker image built successfully: rust-playground-server:latest"
