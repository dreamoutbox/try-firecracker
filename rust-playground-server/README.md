# Rust Playground Server

A self-hosted Rust playground inspired by [play.rust-lang.org](https://play.rust-lang.org/), where each compilation and code execution runs inside an isolated [Firecracker](https://firecracker-microvm.github.io/) microVM.

---

## Architecture

- **Two-Drive Model**:
  - `assets/rust-toolchain.ext4`: Read-only, shared Alpine rootfs containing pre-installed Rust compiler (`rustc`) and `cargo`. Created once by `setup.sh`.
  - `/tmp/run-<id>/code.ext4`: Per-request temporary ext4 workspace containing the user code. Constructed with `mkfs.ext4 -d` without root permissions, mounted inside the guest as `/workspace` on `/dev/vdb`, and cleaned up after execution.
- **Backend**: Axum 0.8 HTTP server with Tokio asynchronous process runner, concurrency semaphore (default max 4 concurrent microVMs), and execution timeout cancellation.
- **Frontend**: Zero-build single-page application embedding CodeMirror 6 with Rust syntax highlighting, dark mode, keyboard shortcuts (`Ctrl+Enter`), and live status indicators.

---

## Prerequisites

- Linux x86_64 host with `/dev/kvm` access.
- Standard utilities: `mkfs.ext4`, `truncate`, `curl`, `tar`.
- Rust toolchain (`cargo`).

---

## Quick Start

1. **Build assets and start the server**:
   ```bash
   make serve
   ```
   Or manually:
   ```bash
   ./rust-playground-server/setup.sh
   cargo run --release --manifest-path rust-playground-server/Cargo.toml
   ```

2. **Open in browser**:
   Navigate to [http://localhost:3000](http://localhost:3000).

---

## API Reference

### `GET /`
Serves the web playground interface.

### `POST /run`
Executes Rust code in an isolated Firecracker microVM.

**Request**:
```json
{
  "code": "fn main() { println!(\"Hello from Firecracker!\"); }"
}
```

**Response**:
```json
{
  "stdout": "   Compiling user_code v0.1.0 (/workspace)\n    Finished `release` profile [optimized] target(s) in 0.58s\nHello from Firecracker!",
  "elapsed_ms": 1420
}
```
