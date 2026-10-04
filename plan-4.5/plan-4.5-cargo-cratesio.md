# Plan 4.5: Cargo Dependency Resolution from crates.io Inside MicroVM

Compile a Rust application with external dependencies (`anyhow`, `serde`, `serde_json`)
**inside** an Alpine Firecracker microVM, using the virtual network established in Plan 4
to fetch crates directly from [crates.io](https://crates.io) at compile time.

---

## Architecture

```
Host (runtime)                               Guest (runtime)
─────────────────────────────────────────    ─────────────────────────────────
TAP Interface: tap1 (172.16.1.1/24)          virtio-net: eth0 (172.16.1.2/24)
  owned by $USER                             gateway: 172.16.1.1
                                             DNS: 1.1.1.1, 8.8.8.8
sysctl: net.ipv4.ip_forward = 1
iptables: NAT masquerade to host egress       /init
                                               → mount /proc /sys /dev
Firecracker:                                   → ip link set lo up
  --no-api --config-file vm_config.json        → ip addr add 172.16.1.2/24 dev eth0
  network-interfaces:                          → ip link set eth0 up
    - iface_id: net0                           → ip route add default via 172.16.1.1
      guest_mac: AA:FC:00:00:00:02             → echo nameserver > /etc/resolv.conf
      host_dev_name: tap1                      → cd /rust_example
                                               → cargo build --release
                                                  (fetches from crates.io via eth0)
                                               → ./target/release/rust_cratesio_example
                                               → reboot -f
                                               ↓
                                           stdout → ttyS0 → host terminal
```

**Key choices:**
- **Dedicated TAP Interface**: Uses `tap1` on `172.16.1.0/24` to avoid collisions with Plan 4's `tap0` (`172.16.0.0/24`), enabling concurrent microVM runs.
- **In-VM Dependency Resolution**: Cargo runs in online mode without `--offline`, fetching crates from crates.io over virtio-net (`eth0` -> `tap1` -> host NAT).
- **CA Certificates Embedded**: `ca-certificates` is installed into the rootfs via `apk.static` so Cargo and OpenSSL can validate `crates.io` TLS certificates.
- **Resource Sizing**: 2 vCPUs and 1024 MiB RAM to provide compilation headroom for procedural macros (`serde_derive`).
- **Disk Sizing**: 2 GiB ext4 rootfs to accommodate the Rust toolchain, Cargo registry index cache, downloaded crate archives, and target build directory.
- **Shutdown**: `reboot -f` inside the guest with `reboot=k panic=1` in `boot_args` ensures clean Firecracker process termination.

**Constraints & Invariants:**
- All paths in scripts and configuration files are relative to the repository root.
- Rebuild caching skips rootfs reconstruction if `assets/rust-cratesio.ext4` is newer than inputs.
- Clean Firecracker exit (exit code 0).

---

### Phase 1: Guest Init Script with Network Setup & In-VM Cargo Build
- Goal: Create `plan-4.5/init.sh` that initializes guest networking, runs `cargo build --release` fetching from crates.io, executes the binary, and cleanly reboots.
- Tasks:
  - [x] Write `plan-4.5/init.sh`:
    - Mount `/proc`, `/sys`, and `/dev`
    - Bring up `lo` and configure `eth0` with static IP `172.16.0.2/24` and gateway `172.16.0.1`
    - Configure `/etc/resolv.conf` with DNS nameservers (`1.1.1.1`, `8.8.8.8`)
    - Export `PATH`, `HOME=/root`, `CARGO_HOME=/root/.cargo`
    - Change directory to `/rust_example`
    - Run `cargo build --release` to fetch and compile dependencies from crates.io
    - Execute `./target/release/rust_cratesio_example`
    - Call `reboot -f` for clean Firecracker exit
  - [x] Set executable permissions on `plan-4.5/init.sh` (`chmod +x`)
- Done when: `plan-4.5/init.sh` exists, is executable, and contains network initialization, online cargo build, execution, and reboot logic.

---

### Phase 2: Setup Script & Ext4 Rootfs Generation
- Goal: Implement `plan-4.5/setup.sh` that prepares Alpine rootfs with Rust toolchain, CA certificates, and `plan-4.5/rust_example`, packing into `assets/rust-cratesio.ext4`.
- Tasks:
  - [x] Write `plan-4.5/setup.sh`:
    - Ensure host prerequisites and KVM access checks
    - Verify `assets/firecracker`, `assets/vmlinux`, and `assets/apk.static`
    - Extract Alpine minirootfs to staging directory
    - Install `rust`, `cargo`, `ca-certificates`, and `curl` via unprivileged `apk.static`
    - Copy `plan-4.5/rust_example` (Cargo.toml, Cargo.lock, src/) into staging rootfs
    - Copy `plan-4.5/init.sh` as `/init` in staging rootfs
    - Pack staging directory into 2 GiB ext4 image (`assets/rust-cratesio.ext4`) using `mkfs.ext4 -d`
    - Preserve non-root ownership on generated assets
  - [x] Set executable permissions on `plan-4.5/setup.sh` (`chmod +x`)
- Done when: Running `./plan-4.5/setup.sh` creates `assets/rust-cratesio.ext4` containing Rust toolchain, CA certificates, and `/rust_example`.

---

### Phase 3: Firecracker VM Configuration & Runner Script
- Goal: Create `plan-4.5/vm_config.json` with TAP network interface and 1024 MiB RAM, and executable runner script `plan-4.5/run.sh`.
- Tasks:
  - [x] Create `plan-4.5/vm_config.json`:
    - `boot-source`: `assets/vmlinux`, `boot_args="console=ttyS0 reboot=k panic=1 init=/init"`
    - `drives`: `assets/rust-cratesio.ext4` (root device, read/write)
    - `machine-config`: `vcpu_count: 2`, `mem_size_mib: 1024`
    - `network-interfaces`: `iface_id: "net0"`, `guest_mac: "AA:FC:00:00:00:01"`, `host_dev_name: "tap0"`
  - [x] Create `plan-4.5/run.sh`:
    - Ensure host TAP and NAT are configured (calling `plan-4/net-setup.sh`)
    - Ensure rootfs image is built (calling `plan-4.5/setup.sh`)
    - Execute Firecracker with `--no-api --config-file plan-4.5/vm_config.json` from repository root
  - [x] Set executable permissions on `plan-4.5/run.sh` (`chmod +x`)
- Done when: `plan-4.5/vm_config.json` is valid JSON and `plan-4.5/run.sh` is executable.

---

### Phase 4: End-to-End Verification
- Goal: Boot microVM via `plan-4.5/run.sh`, let cargo download crates (`anyhow`, `serde`, `serde_json`) from crates.io inside the guest, compile the application, execute the binary, and verify clean exit.
- Tasks:
  - [x] Run `./plan-4.5/run.sh`
  - [x] Verify cargo fetches packages from crates.io and compiles dependencies inside the guest
  - [x] Verify execution of `rust_cratesio_example` outputs expected JSON
  - [x] Verify Firecracker terminates cleanly with exit code 0
  - [x] Mark completed tasks in `plan-4.5/plan-4.5-cargo-cratesio.md` and `TODO.md`
- Done when: `./plan-4.5/run.sh` runs unattended, compiles dependencies fetched from crates.io, prints output, and exits with code 0.
