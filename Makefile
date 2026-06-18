TAG_COMMIT := $(shell git rev-list --abbrev-commit --tags --max-count=1 HEAD)
TAG := $(shell git describe --tags --dirty="-dirty" 2>/dev/null || echo 0.0.0)
TAG_DIRTY=$(shell git status --porcelain --untracked-files=no)
VERSION := $(TAG:v%=%)


BIN_OUTPUT ?= zig-out/bin
BIN_FILES ?= "zini-linux-amd64 zini-linux-arm64"
ZIG ?= zig
IMAGE ?= rawmind/zini
IMAGE_TEST ?= zini-test

.PHONY: build release test fmt fmt-check lint ci run docker e2e-test bench clean

build: ## Build zini (default target: cross-compiles to Linux from non-Linux hosts)
	$(ZIG) build -Dversion=$(VERSION)

release: ## Build static ReleaseSmall binaries for x86_64 + aarch64 Linux
	$(ZIG) build release -Dversion=$(VERSION)
	@cd $(BIN_OUTPUT) && \
	shasum -a 256 zini-linux-amd64 > zini-linux-amd64.sha256 && \
	shasum -a 256 zini-linux-arm64 > zini-linux-arm64.sha256 && \
	cd - > /dev/null

test: ## Run unit tests
	$(ZIG) build test --summary all

fmt: ## Format all Zig sources
	$(ZIG) fmt build.zig src

fmt-check: ## Check formatting without writing changes
	$(ZIG) fmt --check build.zig src

lint: fmt-check ## Lint with zlint (if installed) + check formatting
	@if command -v zlint >/dev/null 2>&1; then \
		echo "zlint"; zlint; \
	else \
		echo "zlint not installed; skipping (install: https://github.com/DonIsaac/zlint)"; \
	fi

ci: lint build release test ## Full local gate: lint, build, release, unit tests

run: ## Build and run zini (use: make run ARGS="-- echo hi")
	$(ZIG) build run -- $(ARGS)

docker: release build ## Build the production image and the test image (release + debug binaries)
	docker build -t $(IMAGE) .
	docker build -t $(IMAGE_TEST) -f Dockerfile.tests --build-arg BASE_IMAGE=$(IMAGE) .

e2e-test: docker ## Run the in-container + host-driven integration suites
	docker run --rm $(IMAGE_TEST) /scripts/integration.sh
	IMAGE=$(IMAGE_TEST) sh test/docker_signal_test.sh
	IMAGE=$(IMAGE_TEST) sh test/watch_test.sh

bench: docker ## Profile the supervision loop (Debug build) as PID 1 in a container
	IMAGE=$(IMAGE_TEST) sh test/bench.sh

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache
