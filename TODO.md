# TODO

- [x] Rust Playground Server. Self-hosted playground server (Axum + Tokio + HTML/CSS/JS) compiling and running user Rust code in isolated Firecracker microVMs.

- [ ] Virtual Networking & Dependency Resolution. Configure host TAP device (tap0) and add network-interfaces configuration to Firecracker.
Verify guest outbound network connectivity to allow cargo to fetch dependencies from crates.io.

- [ ] Host-Guest Communication (vsock)
Configure virtio-vsock for direct stream communication instead of serial console capture.
