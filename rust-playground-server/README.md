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

### Host Native
1. **Start the server**:
   ```bash
   ./rust-playground-server/start.sh
   ```
2. **Build and Test**:
   ```bash
   ./rust-playground-server/build.sh
   ./rust-playground-server/test.sh
   ```

### Docker & Docker Compose
1. **Build image**:
   ```bash
   ./rust-playground-server/dev-build-image.sh
   ```
2. **Start with Docker Compose**:
   ```bash
   ./rust-playground-server/dev-start-compose.sh
   ```
3. **Stop Docker Compose**:
   ```bash
   docker compose -f rust-playground-server/docker-compose.yml down
   ```

Open [http://localhost:3000](http://localhost:3000) in your browser.

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
