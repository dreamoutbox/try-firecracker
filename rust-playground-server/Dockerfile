# Stage 1: Build server binary
FROM rust:1-slim-bookworm AS builder

WORKDIR /build
COPY rust-playground-server/Cargo.toml rust-playground-server/Cargo.lock ./
COPY rust-playground-server/template/ ./template/
COPY rust-playground-server/static/ ./static/
COPY rust-playground-server/src/ ./src/

RUN cargo build --release

# Stage 2: Runtime image with Firecracker dependencies
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    e2fsprogs \
    coreutils \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/rust-playground-server /app/rust-playground-server
COPY assets/firecracker /app/assets/firecracker
COPY assets/vmlinux* /app/assets/
COPY assets/rust-toolchain.ext4 /app/assets/rust-toolchain.ext4

ENV REPO_ROOT=/app
ENV PORT=3000

EXPOSE 3000

ENTRYPOINT ["/app/rust-playground-server"]
