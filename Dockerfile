# A tiny musl base. zini is fully static with no libc, so it runs on any Linux
ARG BASE=bellsoft/alpaquita-linux-base:musl
FROM ${BASE}

ARG TARGETARCH

COPY zig-out/bin/zini-linux-${TARGETARCH} /usr/local/bin/zini
RUN chmod 755 /usr/local/bin/zini

ENTRYPOINT ["/usr/local/bin/zini", "--"]
