# Plan 4.5: Rust Cargo Crates.io Dependency Resolution Example

This directory contains a sample Rust application (`rust_example/`) configured to fetch external dependencies from [crates.io](https://crates.io) (`anyhow`, `serde`, `serde_json`).

## Purpose

- Acts as the guest test workload to verify outbound network resolution and crates.io dependency downloading inside an Alpine Firecracker microVM.
- Builds upon the host virtual networking and TAP configuration established in Plan 4.

## Structure

- `rust_example/Cargo.toml`: Declares dependencies on `anyhow`, `serde`, and `serde_json`.
- `rust_example/src/main.rs`: Structured Rust 2024 program producing JSON output serialized via `serde_json`.
- `rust_example/Cargo.lock`: Pinned dependency lockfile.
