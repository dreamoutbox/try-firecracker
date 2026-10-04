#!/usr/bin/env bash
# Start the Rust Playground Server using Docker Compose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure base assets and toolchain rootfs are built on host
"${SCRIPT_DIR}/setup.sh"

# Check /dev/kvm accessibility
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Warning: /dev/kvm is not read/writable by current user."
    echo "Run setup to configure permissions:"
    echo "  sudo ${SCRIPT_DIR}/setup.sh"
    echo ""
fi

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

echo "Starting playground server via docker compose..."
docker compose -f "${COMPOSE_FILE}" up -d --build "$@"

echo "Container started. Server available at http://localhost:${PORT:-3000}"
echo "To view logs: docker compose -f ${COMPOSE_FILE} logs -f"
echo "To stop:      docker compose -f ${COMPOSE_FILE} down"
