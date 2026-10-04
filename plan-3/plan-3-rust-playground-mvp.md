# Plan 3: Rust Playground MVP — Compile Inside the MicroVM

Compile and run Rust source code **inside** an Alpine Firecracker microVM.
The host prepares a rootfs with a full Rust toolchain baked in; the guest
runs `cargo build` and executes the result, streaming output to the host
terminal via ttyS0.

---

## Architecture

```
Host (setup time)                     Guest (runtime)
────────────────────────────────────  ─────────────────────────────────
apk.static --root <staging> add       /usr/bin/rustc, /usr/bin/cargo
  rust cargo                          /rust_example/src/main.rs
plan-3/rust_example/ (source)    →   /rust_example/Cargo.toml
                                      /init
         ↓
  mkfs.ext4 -d staging
  assets/rust-playground.ext4

plan-3/run.sh                         [init]
  → firecracker --no-api               mount /proc /sys /dev
    --config-file vm_config.json   →   cd /rust_example
                                   →   cargo build --release -q
                                   →   ./target/release/rust_example
                                   →   reboot -f
                                       ↓
                                   stdout → ttyS0 → host terminal
```

**Key choices:**
- `apk.static --root <dir>` installs Alpine packages **unprivileged, no chroot,
  no docker, no root** directly into the staging rootfs directory.
- Rust toolchain is embedded in the ext4 image at setup time; the VM is offline.
- Source code (`plan-3/rust_example/`) is copied into the rootfs at setup time.
- Image is rebuilt only when source or configuration changes.
- Shutdown: `reboot -f` + `reboot=k panic=1` in `boot_args` (same as Plan 2).

**Constraints vs Plan 2:**
- Image size: ~800 MiB (rust 201 MiB + cargo 21 MiB + Alpine base + build cache).
  Use a 1 GiB ext4 image.
- RAM: 512 MiB (cargo needs headroom during compilation).
- First `setup.sh` run downloads packages; subsequent runs skip if the image is up-to-date.

---

## Phase 1 — Guest init script

**Goal:** Create guest init script that mounts filesystems, sets up environment, compiles rust code, executes binary, and initiates clean reboot.

**Tasks:**
- [x] Write `plan-3/init.sh`:
  - Mount `/proc`, `/sys`, `/dev` (devtmpfs)
  - Export `HOME=/root` and `CARGO_HOME=/root/.cargo`
  - Compile `/rust_example` with `cargo build --release -q`
  - Execute `./target/release/rust_example`
  - Call `reboot -f` for clean Firecracker exit
- [x] Set executable permissions on `plan-3/init.sh` (`chmod +x`)

**Done when:** `plan-3/init.sh` exists, is executable, and contains the required boot/compile/shutdown commands.

---

## Phase 2 — Setup script & ext4 rootfs generation

**Goal:** Implement `plan-3/setup.sh` that prepares Alpine rootfs with baked-in Rust toolchain and packs it into `assets/rust-playground.ext4`.

**Tasks:**
- [x] Implement `plan-3/setup.sh` with dependencies and KVM verification
- [x] Fetch/extract `apk.static` in `assets/` if not present
- [x] Stage Alpine minirootfs and run `apk.static --root <staging> add rust cargo`
- [x] Copy `plan-3/rust_example/` (excluding target) and `plan-3/init.sh` into staging rootfs
- [x] Pack staging directory into 1 GiB ext4 image (`assets/rust-playground.ext4`) using `mkfs.ext4 -d`
- [x] Ensure non-root ownership on created assets

**Done when:** Running `plan-3/setup.sh` completes cleanly and `assets/rust-playground.ext4` exists with valid ext4 filesystem containing `/usr/bin/rustc` and `/rust_example`.

---

## Phase 3 — VM config and runner script

**Goal:** Provide Firecracker VM JSON configuration and executable runner script `plan-3/run.sh`.

**Tasks:**
- [x] Create `plan-3/vm_config.json` with 2 vCPUs, 512 MiB RAM, `assets/vmlinux`, `boot_args="console=ttyS0 reboot=k panic=1 init=/init"`, and `assets/rust-playground.ext4` root drive
- [x] Create `plan-3/run.sh` ensuring setup runs, validating KVM, and executing Firecracker with `--no-api --config-file` from repository root
- [x] Make `plan-3/run.sh` executable (`chmod +x`)

**Done when:** `plan-3/vm_config.json` is valid JSON with relative paths, and `plan-3/run.sh` is executable.

---

## Phase 4 — End-to-end verification

**Goal:** Boot microVM via `plan-3/run.sh`, compile Rust inside the guest, run binary, and verify clean exit.

**Tasks:**
- [ ] Execute `./plan-3/run.sh`
- [ ] Verify output banner and `Hello, world!` from guest-compiled binary
- [ ] Verify Firecracker exits cleanly with exit code 0
- [ ] Tick all completed task checkboxes in `plan-3/plan-3-rust-playground-mvp.md`

**Done when:** `./plan-3/run.sh` runs unattended, outputs `Hello, world!`, and exits with code 0.

---

## Key Constraints (inherited from Plan 2)

- All paths in scripts and JSON are **relative** — never `/home/...`.
- Shutdown: `reboot -f` in guest + `reboot=k panic=1` in `boot_args`.
- No inline multi-line scripts in config files.
- Firecracker must be invoked from `REPO_ROOT` (relative drive/kernel paths).
- Use `mkfs.ext4 -d` for rootfs population — no root loop mounts.
- `/dev/kvm` access managed by `setup.sh` via selective `sudo`.
- `apk.static` is the only Alpine tooling needed on the host — no root, no docker, no chroot.
