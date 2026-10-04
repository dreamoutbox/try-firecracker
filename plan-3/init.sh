#!/bin/sh
set -eu

# Mount essential virtual filesystems (devtmpfs is mounted automatically by kernel)
mount -t proc proc /proc
mount -t sysfs sys /sys

# Set standard PATH and environment for cargo/rustc
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root
export CARGO_HOME=/root/.cargo
mkdir -p "${CARGO_HOME}"

echo "=== Linker check: $(which cc) ==="
echo "=== Rustc check: $(which rustc) ==="

echo "=== Compiling Rust inside guest microVM ==="
cd /rust_example
cargo build --offline --release

echo "=== Running guest-compiled Rust binary ==="
./target/release/rust_example

echo "=== MicroVM execution complete ==="
reboot -f
