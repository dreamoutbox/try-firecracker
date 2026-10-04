#!/usr/bin/env bash
# Teardown host TAP device and remove iptables rules for Plan 4.5.
set -euo pipefail

TAP_DEV="${TAP_DEV:-tap1}"
GUEST_SUBNET="${GUEST_SUBNET:-172.16.1.0/24}"

# Helper: execute command as root using sudo if needed
run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_egress_interface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [ -z "${iface}" ]; then
        iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    fi
    echo "${iface}"
}

main() {
    local host_iface
    host_iface="$(detect_egress_interface)"

    echo "Cleaning up iptables rules for ${TAP_DEV}..."
    if [ -n "${host_iface}" ]; then
        run_privileged iptables -t nat -D POSTROUTING -o "${host_iface}" -s "${GUEST_SUBNET}" -j MASQUERADE 2>/dev/null || true
        run_privileged iptables -D FORWARD -i "${TAP_DEV}" -o "${host_iface}" -j ACCEPT 2>/dev/null || true
    fi

    if ip link show dev "${TAP_DEV}" >/dev/null 2>&1; then
        echo "Deleting TAP device '${TAP_DEV}'..."
        run_privileged ip link delete dev "${TAP_DEV}"
    else
        echo "TAP device '${TAP_DEV}' does not exist."
    fi

    echo "Network cleanup complete."
}

main "$@"
