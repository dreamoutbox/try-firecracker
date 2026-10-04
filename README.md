# try-firecracker

A collection of experiments and progressive demos exploring [Firecracker](https://firecracker-microvm.github.io/) microVMs on Linux (x86_64).

## Prerequisites

- Linux host or WSL2 with nested virtualization enabled
- Read/write access to `/dev/kvm`
- Standard host utilities: `curl`, `tar`, `truncate`, `mkfs.ext4`, `iptables`, `iproute2`

Run the one-time WSL/KVM permission setup if needed:
```bash
./setup-wsl.sh
```

---

## Demo Plans

Each `plan-*` directory represents a distinct milestone in configuring, networking, and running workloads inside Firecracker:

### [plan-1](./plan-1): REST API Boot (Ubuntu)
- **Goal**: Boot an upstream Firecracker Ubuntu CI rootfs and kernel using Firecracker's Unix domain socket REST API.
- **Key Files**: `setup.sh`, `bootstrap.sh`, `boot.sh`
- **Run**:
  ```bash
  cd plan-1 && ./setup.sh && ./boot.sh
  ```

### [plan-2](./plan-2): Config File Boot (Alpine Minimal)
- **Goal**: Unprivileged, headless Alpine microVM boot without the REST API socket, using Firecracker's `--no-api --config-file` mode. Shuts down cleanly via `reboot -f` and kernel `reboot=k`.
- **Key Files**: `setup.sh`, `run.sh`, `init.sh`, `vm_config.json`
- **Run**:
  ```bash
  ./plan-2/run.sh
  ```

### [plan-3](./plan-3): Rust Playground MVP (Offline In-VM Compilation)
- **Goal**: Bake a full Rust toolchain (`rust`, `cargo`, `gcc`) into an Alpine rootfs using unprivileged `apk.static`. The guest boots, compiles source code (`/rust_example`) inside the VM offline, executes the binary, and exits.
- **Key Files**: `setup.sh`, `run.sh`, `init.sh`, `vm_config.json`, `rust_example/`
- **Run**:
  ```bash
  ./plan-3/run.sh
  ```

### [plan-4](./plan-4): Virtual Networking & Internet Access
- **Goal**: Configure a host TAP interface (`tap0`) and iptables NAT masquerading. The guest configures a static IP (`172.16.0.2/24`), sets up DNS, verifies outbound HTTPS internet connectivity using `curl`, and exits cleanly.
- **Key Files**: `net-setup.sh`, `net-cleanup.sh`, `setup.sh`, `run.sh`, `init.sh`, `vm_config.json`
- **Run**:
  ```bash
  ./plan-4/run.sh
  ```

### [plan-4.5](./plan-4.5): Cargo Dependency Resolution from crates.io
- **Goal**: Run Cargo in online mode inside the microVM over a dedicated TAP device (`tap1`, `172.16.1.0/24`). The guest resolves, downloads, and compiles 12 external dependencies from [crates.io](https://crates.io) (`anyhow`, `serde`, `serde_json`), runs the binary, and logs JSON output to the host console.
- **Key Files**: `net-setup.sh`, `net-cleanup.sh`, `setup.sh`, `run.sh`, `init.sh`, `vm_config.json`, `rust_example/`
- **Run**:
  ```bash
  ./plan-4.5/run.sh
  ```

---

## Additional Applications

### [rust-playground-server](./rust-playground-server)
A self-hosted Rust playground web application built with Axum, Tokio, and Vanilla HTML/CSS/JS. It accepts user Rust snippets from a browser editor, compiles and executes them inside isolated Firecracker microVMs, and streams output back in real time.
