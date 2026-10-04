# Rust Playground Server — Plan

A self-hosted Rust playground (like [play.rust-lang.org](https://play.rust-lang.org/)) where each code execution
runs inside an isolated Firecracker microVM. Built on the foundation established in [../plan-3](../plan-3).

---

## Architecture

```
Browser (HTML/CSS/JS)
  │  POST /run  { code: "fn main() { ... }" }
  │  GET  /     → editor UI
  ▼
┌─────────────────────────────────────────────┐
│  Axum HTTP Server (rust-playground-server)  │
│                                             │
│  POST /run                                  │
│    1. Receive code payload                  │
│    2. Write code into temp workspace ext4   │
│    3. Spawn Firecracker microVM             │
│    4. Read ttyS0 pipe → response JSON       │
│    5. Enforce timeout + cleanup             │
└─────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────┐
│  Firecracker microVM (per request)           │
│  Kernel: assets/vmlinux                      │
│  Drive 0 (ro): assets/rust-toolchain.ext4   │  ← shared read-only toolchain
│  Drive 1 (rw): /tmp/run-<id>/code.ext4      │  ← per-request writable workspace
│                                              │
│  Guest /init:                                │
│    mount /proc /sys                          │
│    mount /dev/vdb at /workspace              │
│    cd /workspace && cargo build --offline    │
│    execute binary                            │
│    reboot -f                                 │
└──────────────────────────────────────────────┘
```

**Key decisions:**

- **Read-only toolchain image** (`assets/rust-toolchain.ext4`): Contains Alpine + Rust toolchain, shared
  across all concurrent runs. Built once by `setup.sh`. Never mutated at runtime.
- **Per-request writable workspace image** (`/tmp/run-<id>/code.ext4`): Small ext4 image (~64 MiB) containing
  only `Cargo.toml` + `src/main.rs`. Created and destroyed per request.
- **Serial console capture**: Firecracker connects guest ttyS0 to its own stdout. The server reads from the
  child process stdout pipe and returns it as the response.
- **No networking in guest**: `cargo build --offline` only. Dependencies must be pre-vendored into the
  toolchain image at setup time.
- **Concurrency**: Each request gets its own Firecracker process + temp workspace. Max concurrent runs
  bounded by a semaphore (`MAX_CONCURRENT_RUNS`).
- **Timeout enforcement**: Handler races microVM process against `tokio::time::timeout(30s)`. On timeout,
  Firecracker child is killed and workspace cleaned up.

---

## Directory Layout (after implementation)

```
rust-playground-server/
├── plan.md                      ← this file
├── Cargo.toml                   ← bin crate: axum, tokio, uuid, anyhow, tracing
├── src/
│   ├── main.rs                  ← server entry, routes, tracing init
│   ├── runner.rs                ← microVM spawn, serial capture, timeout, cleanup
│   └── workspace.rs             ← per-request ext4 workspace creation
├── static/
│   └── index.html               ← editor UI (HTML + CSS + JS, no build step)
├── setup.sh                     ← builds rust-toolchain.ext4
├── guest-init/
│   └── init.sh                  ← guest /init: mount, cargo build, exec, reboot -f
└── template/
    └── Cargo.toml               ← embedded template for user code crate
```

---

## Phases

### Phase 1: Toolchain Image & Guest Init

**Goal**: Produce `assets/rust-toolchain.ext4` — a read-only Alpine + Rust base image with a new
`guest-init/init.sh` that mounts a second writable workspace drive.

**Tasks**:
- [x] Write `setup.sh` reusing `plan-3/setup.sh` helpers to build `assets/rust-toolchain.ext4`
      (Alpine minirootfs + rust + cargo, no source code baked in).
- [x] Write `guest-init/init.sh`:
      - Mount `/proc`, `/sys`.
      - Export standard `PATH`, `HOME=/root`, `CARGO_HOME=/root/.cargo`.
      - Mount `/dev/vdb` at `/workspace` (`mount /dev/vdb /workspace`).
      - `cd /workspace && cargo build --offline --release -q 2>&1`.
      - Execute `./target/release/user_code`.
      - `reboot -f`.
- [x] Copy `guest-init/init.sh` into the toolchain rootfs staging directory as `/init` during `setup.sh`.
- [x] Verify: `./setup.sh` completes without root; `assets/rust-toolchain.ext4` contains `/usr/bin/rustc` and `/init`.

**Done when**: A manual Firecracker invocation with a hand-crafted workspace drive successfully compiles
and runs a minimal `fn main()` snippet using the toolchain image.

---

### Phase 2: Per-Request Workspace Builder (`workspace.rs`)

**Goal**: Rust function that takes a code string and produces a small ext4 workspace image on disk.

**Tasks**:
- [x] Add crate `Cargo.toml` with deps: `axum`, `tokio` (full), `uuid` (v4), `anyhow`, `tracing`, `tracing-subscriber`.
- [x] Implement `workspace::create(code: &str, run_id: &Uuid) -> anyhow::Result<PathBuf>`:
      - Create `/tmp/run-<id>/staging/src/`.
      - Write template `Cargo.toml` (package name `user_code`, edition 2024, no external deps).
      - Write `src/main.rs` with user code.
      - Run `mkfs.ext4 -d /tmp/run-<id>/staging /tmp/run-<id>/code.ext4 64M`.
      - Return path to `code.ext4`.
- [x] Implement `workspace::cleanup(run_id: &Uuid)`: `tokio::fs::remove_dir_all("/tmp/run-<id>/")`.
- [x] Unit test: create workspace from `r#"fn main(){println!("hi");}"#`, assert ext4 path exists.

**Done when**: `cargo test -p rust-playground-server workspace` passes.

---

### Phase 3: MicroVM Runner (`runner.rs`)

**Goal**: Spawn Firecracker for a given workspace, capture serial output, enforce timeout.

**Tasks**:
- [x] Implement `runner::run(repo_root: &Path, workspace_ext4: &Path, run_id: &Uuid) -> anyhow::Result<String>`:
      - Serialize per-run `vm_config.json` into `/tmp/run-<id>/vm_config.json` with:
        - `boot-source`: `assets/vmlinux`, `console=ttyS0 reboot=k panic=1 init=/init`.
        - `drives[0]`: `assets/rust-toolchain.ext4`, root device, read-only.
        - `drives[1]`: workspace ext4 (absolute path), not root, read-write.
        - `machine-config`: 2 vCPUs, 512 MiB RAM.
      - Spawn `assets/firecracker --no-api --config-file /tmp/run-<id>/vm_config.json`
        as `tokio::process::Command` with `stdout(Stdio::piped())`, `stderr(Stdio::piped())`, `current_dir(repo_root)`.
      - `child.wait_with_output().await` to collect stdout bytes.
      - Return stdout as `String` (lossy UTF-8).
- [x] In `main.rs`: wrap call in `tokio::time::timeout(Duration::from_secs(30), ...)`.
      On `Elapsed`, kill child, return `Err("Execution timed out")`.
- [x] Add `MAX_CONCURRENT_RUNS: usize = 4` semaphore (`tokio::sync::Semaphore`) in `main.rs`.
      Acquire permit before creating workspace; release on drop.
- [x] Integration test: run `r#"fn main(){println!("firecracker-ok");}"#`, assert stdout contains `firecracker-ok`.

**Done when**: Integration test passes; `cargo clippy -- -D warnings` clean.

---

### Phase 4: Axum HTTP Server (`main.rs`)

**Goal**: Working HTTP server wiring routes, handler, concurrency guard, and tracing.

**Tasks**:
- [x] `GET /` → `include_str!("../static/index.html")` as `text/html`.
- [x] `POST /run` body: `{ "code": "..." }` → response: `{ "stdout": "...", "elapsed_ms": 1234 }` or
      `{ "error": "..." }`. Always HTTP 200.
- [x] `tracing_subscriber::fmt().with_env_filter(EnvFilter::from_default_env()).init()` in `main`.
- [x] Bind `0.0.0.0:${PORT:-3000}`.
- [x] Graceful shutdown: `axum::serve(...).with_graceful_shutdown(shutdown_signal())`.

**Done when**: `curl -s -X POST http://localhost:3000/run -H 'Content-Type: application/json'
-d '{"code":"fn main(){println!(\"ok\");}"}' | jq .stdout` returns `"ok\n"`.

---

### Phase 5: Frontend (`static/index.html`)

**Goal**: Single-file editor UI — no build step, no npm.

**Tasks**:
- [x] Load CodeMirror 6 and `@codemirror/lang-rust` via ESM CDN (`esm.sh` or `cdn.jsdelivr.net`).
- [x] Rust syntax highlighting; dark theme (`oneDark` or custom).
- [x] "Run" button: POST to `/run`, display output in a pane below the editor.
- [x] Spinner/disabled state while running; re-enable on response.
- [x] Show `elapsed_ms` in output pane footer.
- [x] Default snippet: `fn main() {\n    println!(\"Hello from Firecracker!\");\n}`.
- [x] Keyboard shortcut: `Ctrl+Enter` to run.
- [x] Minimal chrome: editor fills the viewport, output pane below. Dark background.

**Done when**: UI loads at `http://localhost:3000`, user can edit and run code, output appears.

---

### Phase 6: Integration & Polish

**Goal**: End-to-end working server ready to run with a single command.

**Tasks**:
- [x] Write `rust-playground-server/README.md` with prerequisites and `make serve` instructions.
- [x] Add root `Makefile` target `serve`: runs `rust-playground-server/setup.sh` then
      `cargo run --release --manifest-path rust-playground-server/Cargo.toml`.
- [x] Verify concurrent requests: 2 browser tabs run simultaneously without interference.
- [x] Verify timeout: snippet with `loop {}` returns `"Execution timed out"` within configured timeout window.
- [x] Update `../TODO.md` checkboxes.
- [x] Commit: `feat(rust-playground-server): initial working playground server`.

**Done when**: `make serve` starts the server from a clean checkout; end-to-end smoke test passes.

---

## Key Constraints

- **Relative paths in vm_config**: All drive/kernel paths are relative to `REPO_ROOT`. Runner must invoke
  Firecracker with `current_dir(repo_root)`.
- **No root at runtime**: `mkfs.ext4 -d` for workspace images. Server runs as the current user.
- **No inline scripts**: Shell logic lives in `.sh` files, never inlined in Rust strings or JSON.
- **Guest shutdown**: `reboot -f` + `reboot=k panic=1` — same invariant as plan-3.
- **Offline cargo**: No guest networking. Template `Cargo.toml` has zero external deps.
- **Error surface**: `runner.rs` and `workspace.rs` return `anyhow::Result`. Handler always returns HTTP 200
  with structured JSON; build stderr is part of `stdout` (captured from ttyS0).
- **Tracing**: Use `tracing` with structured fields. No `println!` for diagnostics.

---

## Risks & Open Questions

| # | Topic | Risk | Mitigation |
|---|-------|------|------------|
| 1 | Serial output format | Boot noise from kernel/init mixed with user output on ttyS0. | Bracket user output with sentinel lines in `guest-init/init.sh`; strip everything outside. |
| 2 | Workspace image size | 64 MiB may be tight for `cargo` target dir during compilation. | Cargo build artifacts live in the writable workspace image. Start at 64 MiB; bump to 256 MiB if needed. |
| 3 | Concurrent KVM | Host may cap concurrent VMs. | `MAX_CONCURRENT_RUNS = 4`; document in README. |
| 4 | Offline vendoring | `cargo build --offline` fails if deps are missing from toolchain image. | Template has no external deps. Document this limitation clearly in the UI. |
| 5 | ttyS0 as pipe | Firecracker `--no-api` may need a PTY for ttyS0. | Use `Stdio::piped()` first; if output is garbled, fall back to `pty` crate or named pipe. |
| 6 | Second drive mounting | `/dev/vdb` path inside guest depends on virtio ordering. | Drive ordering in `vm_config.json` is deterministic (index 0 = root, index 1 = workspace). |
