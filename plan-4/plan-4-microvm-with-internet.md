# Plan 4: MicroVM with Virtual Networking & Internet Access

Configure virtual networking for an Alpine Firecracker microVM using a host TAP
interface (`tap0`) and NAT masquerading. Verify outbound Internet connectivity
from inside the guest with a simple `curl` request, streaming the result to
the host serial console before shutting down cleanly.

---

## Architecture

```
Host (runtime)                               Guest (runtime)
─────────────────────────────────────────    ─────────────────────────────────
TAP Interface: tap0 (172.16.0.1/24)          virtio-net: eth0 (172.16.0.2/24)
  owned by $USER                             gateway: 172.16.0.1
                                             DNS: 1.1.1.1, 8.8.8.8
sysctl: net.ipv4.ip_forward = 1
iptables: NAT masquerade to host egress       /init
                                               → mount /proc /sys /dev
Firecracker:                                   → ip link set lo up
  --no-api --config-file vm_config.json        → ip addr add 172.16.0.2/24 dev eth0
  network-interfaces:                          → ip link set eth0 up
    - iface_id: net0                           → ip route add default via 172.16.0.1
      guest_mac: AA:FC:00:00:00:01             → echo nameserver > /etc/resolv.conf
      host_dev_name: tap0                      → curl -sSf https://icanhazip.com
                                               → reboot -f
                                               ↓
                                           stdout → ttyS0 → host terminal
```

**Key choices:**
- **Static Guest Networking**: Fixed IP (`172.16.0.2/24`), default gateway (`172.16.0.1`), and static DNS (`1.1.1.1`) inside `/init`. Fast boot without requiring a DHCP server on the host.
- **Unprivileged TAP**: Host TAP device `tap0` is provisioned with `user "$USER"` permissions so Firecracker can run unprivileged.
- **NAT Masquerade**: `iptables` masquerades outbound traffic on the primary host interface (e.g. `eth0`), and forwards established/related responses back to `tap0`.
- **Rootfs with Curl**: Built with `apk.static --root <staging> add curl ca-certificates` to enable HTTPS support without requiring Docker or root chroot.
- **Shutdown**: `reboot -f` inside the guest with `reboot=k panic=1` in `boot_args` ensures clean Firecracker process termination.

**Constraints & Invariants:**
- All paths in scripts and configuration files are relative to the repository root.
- MicroVM runs offline from a disk perspective (read-only rootfs or temporary writable copy), but communicates across the virtual network.
- Ext4 rootfs size: 256 MiB (sufficient for Alpine base, curl, and CA certificates).
- Machine config: 1 vCPU, 256 MiB RAM.

---

### Phase 1: Host Virtual Network & TAP Management Scripts
- Goal: Create idempotent host network setup and teardown scripts for TAP interface provisioning, IP forwarding, and iptables NAT masquerading.
- Tasks:
  - [x] Write `plan-4/net-setup.sh`:
    - Detect primary outbound network interface using `ip route get 1.1.1.1`
    - Create `tap0` interface owned by `$USER` (`ip tuntap add dev tap0 mode tap user "$USER"`) if missing
    - Assign `172.16.0.1/24` to `tap0` and bring interface up (`ip link set dev tap0 up`)
    - Enable host IPv4 forwarding (`sysctl -w net.ipv4.ip_forward=1`)
    - Add idempotent `iptables` NAT masquerade and FORWARD rules between `tap0` and outbound interface
  - [x] Write `plan-4/net-cleanup.sh`:
    - Remove iptables NAT and FORWARD rules created by setup
    - Delete `tap0` interface (`ip link delete dev tap0`)
  - [x] Set executable permissions on both scripts (`chmod +x`)
- Done when: Running `./plan-4/net-setup.sh` configures `tap0` with `172.16.0.1/24`, enables forwarding, and `./plan-4/net-cleanup.sh` removes the interface and rules cleanly.

---

### Phase 2: Guest Init Script with Network Setup & Curl Probe
- Goal: Create guest init script that configures guest networking, verifies DNS resolution, performs an outbound curl test to public internet, and reboots.
- Tasks:
  - [x] Write `plan-4/init.sh`:
    - Mount `/proc`, `/sys`, and `/dev`
    - Export standard `PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin`
    - Bring up loopback interface (`ip link set lo up`)
    - Configure `eth0` with static IP `172.16.0.2/24` and set link up
    - Add default route via gateway `172.16.0.1 dev eth0`
    - Configure DNS in `/etc/resolv.conf` with `nameserver 1.1.1.1` and `nameserver 8.8.8.8`
    - Execute curl test: `curl -sSf https://icanhazip.com` (with fallback to `curl -Is https://cloudflare.com`)
    - Output result banner to serial console
    - Initiate clean exit via `reboot -f`
  - [x] Set executable permissions on `plan-4/init.sh` (`chmod +x`)
- Done when: `plan-4/init.sh` exists, is executable, and contains full network initialization, curl execution, and reboot logic.

---

### Phase 3: Setup Script & Alpine Network Rootfs Generation
- Goal: Implement `plan-4/setup.sh` that prepares Alpine rootfs with curl and TLS certificates, packing it into `assets/alpine-net.ext4`.
- Tasks:
  - [x] Write `plan-4/setup.sh` with host prerequisites and KVM access checks
  - [x] Fetch/verify `assets/firecracker`, `assets/vmlinux`, and `assets/apk.static`
  - [x] Extract Alpine minirootfs to staging directory
  - [x] Install `curl` and `ca-certificates` into staging rootfs using `apk.static --root <staging>`
  - [x] Copy `plan-4/init.sh` as `/init` in staging rootfs
  - [x] Pack staging directory into 256 MiB ext4 image (`assets/alpine-net.ext4`) using `mkfs.ext4 -d`
  - [x] Preserve non-root ownership on generated assets
- Done when: `plan-4/setup.sh` executes cleanly and generates `assets/alpine-net.ext4` with valid ext4 filesystem containing `/usr/bin/curl` and `/init`.

---

### Phase 4: Firecracker VM Configuration & Runner Script
- Goal: Provide Firecracker VM JSON configuration with virtio-net interface and executable runner script `plan-4/run.sh`.
- Tasks:
  - [x] Create `plan-4/vm_config.json`:
    - `boot-source`: `assets/vmlinux`, `boot_args="console=ttyS0 reboot=k panic=1 init=/init"`
    - `drives`: `assets/alpine-net.ext4` (root device, read/write)
    - `machine-config`: `vcpu_count: 1`, `mem_size_mib: 256`
    - `network-interfaces`: `iface_id: "net0"`, `guest_mac: "AA:FC:00:00:00:01"`, `host_dev_name: "tap0"`
  - [x] Create `plan-4/run.sh`:
    - Ensure host network setup is active (calling `plan-4/net-setup.sh`)
    - Ensure rootfs image exists (calling `plan-4/setup.sh`)
    - Execute Firecracker with `--no-api --config-file plan-4/vm_config.json` from repository root
  - [x] Set executable permissions on `plan-4/run.sh` (`chmod +x`)
- Done when: `plan-4/vm_config.json` is valid JSON referencing relative paths and `network-interfaces`, and `plan-4/run.sh` is executable.

---

### Phase 5: End-to-End Verification
- Goal: Boot microVM via `plan-4/run.sh`, establish network connection, query public internet endpoint via curl, and verify clean exit.
- Tasks:
  - [ ] Run `./plan-4/run.sh`
  - [ ] Verify guest brings up `eth0` and receives public IP response via `curl`
  - [ ] Verify Firecracker terminates cleanly with exit code 0
  - [ ] Tick completed tasks in `plan-4/plan-4-microvm-with-internet.md`
- Done when: `./plan-4/run.sh` executes unattended, outputs the public IP or HTTP response via curl, and exits with code 0.

---

## Unknowns, Risks, and Assumptions

1. **Host Outbound Interface Detection**:
   - In WSL2 and multi-NIC environments, default routing device must be dynamically determined (e.g. `ip route get 1.1.1.1 | awk '{print $5; exit}'`).
2. **Firewall / iptables Backend**:
   - Host systems using `iptables-nft` vs `iptables-legacy` or UFW/nftables default drop policies may require explicit FORWARD policy updates (`iptables -P FORWARD ACCEPT` or specific bidirectional rules).
3. **DNS Forwarding / Resolution**:
   - Assumes outbound UDP/TCP port 53 to public resolvers (`1.1.1.1`, `8.8.8.8`) is allowed by host network. If blocked in corporate/VPN environments, host `/etc/resolv.conf` nameserver can be inherited.
