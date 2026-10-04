.PHONY: all setup build test serve

all: build

setup:
	./rust-playground-server/setup.sh

build:
	cargo build --release --manifest-path rust-playground-server/Cargo.toml

test:
	cargo test --manifest-path rust-playground-server/Cargo.toml

serve:
	./rust-playground-server/start.sh
