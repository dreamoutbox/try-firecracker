#!/bin/sh
set -eu

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys

# Set standard PATH and environment for cargo/rustc
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root
export CARGO_HOME=/root/.cargo
mkdir -p "${CARGO_HOME}"

echo "=== Initializing Guest Networking ==="

# Bring up loopback interface
ip link set lo up

# Configure eth0 with static IP and default gateway (tap1 / 172.16.1.0/24)
ip addr add 172.16.1.2/24 dev eth0
ip link set eth0 up
ip route add default via 172.16.1.1 dev eth0

# Configure DNS nameservers
mkdir -p /etc
cat <<'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "Guest IP: $(ip -4 addr show dev eth0 | awk '/inet / {print $2}')"
echo "Default Route: $(ip route | grep default)"

echo "=== Verifying crates.io Reachability ==="
if curl -sSf -I -m 5 https://crates.io >/dev/null 2>&1; then
    echo "crates.io is reachable via HTTPS."
else
    echo "Warning: crates.io HTTP probe returned non-zero; attempting cargo fetch anyway."
fi

echo "=== Fetching and Compiling Dependencies from crates.io ==="
cd /rust_example
cargo build --release

echo "=== Running Guest-Compiled Rust Binary ==="
./target/release/rust_cratesio_example

echo "=== Cargo crates.io verification successful ==="
reboot -f
