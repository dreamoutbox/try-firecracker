#!/bin/sh
set -eu

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys

# Export standard system PATH
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root

echo "=== Initializing Guest Networking ==="

# Bring up loopback interface
ip link set lo up

# Configure eth0 with static IP and default gateway
ip addr add 172.16.0.2/24 dev eth0
ip link set eth0 up
ip route add default via 172.16.0.1 dev eth0

# Configure DNS nameservers
mkdir -p /etc
cat <<'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "Guest IP: $(ip -4 addr show dev eth0 | grep -oP 'inet \K[\d.]+')"
echo "Default Route: $(ip route | grep default)"

echo "=== Testing Internet Connectivity via curl ==="
if curl -sSf -m 10 https://icanhazip.com > /tmp/public_ip.txt; then
    PUBLIC_IP="$(cat /tmp/public_ip.txt)"
    echo "Public IP fetched successfully: ${PUBLIC_IP}"
elif curl -sSf -m 10 https://cloudflare.com/cdn-cgi/trace > /tmp/cf_trace.txt; then
    echo "Cloudflare probe response:"
    cat /tmp/cf_trace.txt
else
    echo "Error: outbound curl request failed."
    reboot -f
fi

echo "=== Internet connectivity verified successfully ==="
reboot -f
