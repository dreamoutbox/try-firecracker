#!/bin/sh
set -eu

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Setup environment for cargo
export HOME=/root
export CARGO_HOME=/root/.cargo
mkdir -p "${CARGO_HOME}"

echo "=== Compiling Rust inside guest microVM ==="
cd /rust_example
cargo build --offline --release

echo "=== Running guest-compiled Rust binary ==="
./target/release/rust_example

echo "=== MicroVM execution complete ==="
reboot -f
