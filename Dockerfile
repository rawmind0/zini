# Minimal Linux image to run the integration suite with zini as PID 1.
#
# zini is built on the host (Zig cross-compiles a static, libc-free binary), so
# this image only needs to copy the arch-appropriate binary in. Build both
# release binaries first, then build/run the image:
#
#   zig build release            # produces zig-out/bin/zini-{x86_64,aarch64}-linux
#   docker build -t zini-test .
#   docker run --rm zini-test
#
# Or simply: make docker-test

# A tiny musl base. zini is fully static with no libc, so it runs on any Linux
# regardless of the base's libc — using a musl distro also demonstrates that.
# Override with e.g. `--build-arg BASE=debian:bookworm-slim` if desired.
ARG BASE=bellsoft/alpaquita-linux-base:musl
FROM ${BASE}

# Provided automatically by BuildKit: "amd64" or "arm64".
ARG TARGETARCH

COPY zig-out/bin/zini-x86_64-linux zig-out/bin/zini-aarch64-linux /tmp/bins/
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) src=/tmp/bins/zini-x86_64-linux ;; \
      arm64) src=/tmp/bins/zini-aarch64-linux ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    install -m 0755 "$src" /usr/local/bin/zini; \
    rm -rf /tmp/bins

COPY test/integration.sh /usr/local/bin/integration.sh
RUN chmod +x /usr/local/bin/integration.sh

# Run the suite under zini itself (zini becomes PID 1).
ENTRYPOINT ["/usr/local/bin/zini", "--"]
CMD ["/usr/local/bin/integration.sh"]
