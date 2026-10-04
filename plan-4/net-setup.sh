#!/usr/bin/env bash
# Setup host TAP device, IP forwarding, and iptables NAT masquerading for Plan 4.
set -euo pipefail

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1/24}"
GUEST_SUBNET="${GUEST_SUBNET:-172.16.0.0/24}"
TARGET_USER="${SUDO_USER:-$USER}"

# Helper: execute command as root using sudo if needed
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
    for cmd in ip sysctl iptables; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                ip) missing_pkgs+=("iproute2") ;;
                sysctl) missing_pkgs+=("procps") ;;
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

# Helper: identify host default egress network interface
detect_egress_interface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [ -z "${iface}" ]; then
        iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    fi
    if [ -z "${iface}" ]; then
        echo "Error: unable to determine host egress network interface." >&2
        exit 1
    fi
    echo "${iface}"
}

main() {
    ensure_dependencies

    local host_iface
    host_iface="$(detect_egress_interface)"
    echo "Host egress interface: ${host_iface}"

    # 1. Create TAP interface if it does not already exist
    if ! ip link show dev "${TAP_DEV}" >/dev/null 2>&1; then
        echo "Creating TAP device '${TAP_DEV}' owned by ${TARGET_USER}..."
        run_privileged ip tuntap add dev "${TAP_DEV}" mode tap user "${TARGET_USER}"
    else
        echo "TAP device '${TAP_DEV}' already exists."
    fi

    # 2. Configure TAP interface address
    if ! ip addr show dev "${TAP_DEV}" | grep -q "${TAP_IP%/*}"; then
        echo "Assigning ${TAP_IP} to ${TAP_DEV}..."
        run_privileged ip addr add "${TAP_IP}" dev "${TAP_DEV}"
    fi

    # 3. Bring up TAP interface
    run_privileged ip link set dev "${TAP_DEV}" up

    # 4. Enable IPv4 forwarding
    echo "Enabling IPv4 forwarding..."
    run_privileged sysctl -q -w net.ipv4.ip_forward=1

    # 5. Configure iptables NAT masquerading and packet forwarding (idempotent)
    echo "Configuring iptables NAT rules..."
    if ! run_privileged iptables -t nat -C POSTROUTING -o "${host_iface}" -s "${GUEST_SUBNET}" -j MASQUERADE 2>/dev/null; then
        run_privileged iptables -t nat -A POSTROUTING -o "${host_iface}" -s "${GUEST_SUBNET}" -j MASQUERADE
    fi

    if ! run_privileged iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        run_privileged iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fi

    if ! run_privileged iptables -C FORWARD -i "${TAP_DEV}" -o "${host_iface}" -j ACCEPT 2>/dev/null; then
        run_privileged iptables -A FORWARD -i "${TAP_DEV}" -o "${host_iface}" -j ACCEPT
    fi

    echo "Network setup complete:"
    echo "TAP device : ${TAP_DEV} (${TAP_IP})"
    echo "Egress     : ${host_iface}"
    echo "NAT Subnet : ${GUEST_SUBNET}"
}

main "$@"
