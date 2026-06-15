# Thin convenience wrapper around `zig build`. `zig build` remains the source of truth.

ZIG ?= zig
IMAGE ?= zini-test

.PHONY: build release test fmt fmt-check run docker-test clean

build: ## Build zini (default target: cross-compiles to Linux from non-Linux hosts)
	$(ZIG) build

release: ## Build static ReleaseSmall binaries for x86_64 + aarch64 Linux
	$(ZIG) build release

test: ## Run unit tests
	$(ZIG) build test

fmt: ## Format all Zig sources
	$(ZIG) fmt build.zig src

fmt-check: ## Check formatting without writing changes
	$(ZIG) fmt --check build.zig src

run: ## Build and run zini (use: make run ARGS="-- echo hi")
	$(ZIG) build run -- $(ARGS)

docker-test: release ## Build the Linux test image and run the integration suites
	docker build -t $(IMAGE) .
	docker run --rm $(IMAGE)
	IMAGE=$(IMAGE) sh test/docker_signal_test.sh

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
