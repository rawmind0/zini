# zini

**zini** is a simple `init` for containers running.

It spawns a single child process, forwards signals to it, reaps zombie 
processes and optionally watch for file changes to restart child process.

## Origin

zini is a **rewrite of [tini](https://github.com/krallin/tini) from C to
[Zig](https://ziglang.org/)**. tini ("the simplest init you could think of") is
written in C by Thomas Orozco and contributors. This project ports its logic
faithfully to Zig while producing a **statically linked, libc-free** binary
(every operation goes through raw Linux syscalls via `std.os.linux` / `std.posix`).

Behavior, command-line flags, environment variables, and exit-code semantics
match tini, so zini is intended to be a drop-in replacement. The original
`TINI_*` environment variable names are kept on purpose for compatibility.

Beyond the faithful port, zini adds one **optional, opt-in** feature tini does
not have: [file watching with restart/reload](#file-watching--hot-reload-optional)
(handy for hot-reloading config or rotated TLS certs). With no `--watch` flag,
zini is byte-for-byte tini behavior.

## Why use an init in a container?

Without a real init as PID 1:

- **Zombies pile up.** Orphaned processes are re-parented to PID 1, which is
  expected to reap them. A typical app process doesn't, so zombies accumulate
  and can exhaust the PID space.
- **Signals don't behave.** PID 1 gets special signal treatment; default signal
  dispositions don't apply, so e.g. `SIGTERM` may be ignored and your container
  won't stop cleanly.

zini sits at PID 1, forwards signals to your program, and reaps zombies.

## Usage

```
zini [OPTIONS] PROGRAM -- [ARGS] | --version
```

Typically as a container entrypoint:

```dockerfile
ARG TARGETARCH
ENV ZINI_VERSION=0.0.1
RUN curl -LO https://github.com/rawmind0/zini/releases/download/${ZINI_VERSION}/zini-${TARGETOS}-${TARGETARCH} && \
    curl -sL https://github.com/rawmind0/zini/releases/download/${ZINI_VERSION}/zini-${TARGETOS}-${TARGETARCH}.sha256sum | sha256sum -c - && \
    chmod +x zini-${TARGETOS}-${TARGETARCH}  && mv zini-${TARGETOS}-${TARGETARCH} /usr/local/bin/zini
ENTRYPOINT ["/usr/local/bin/zini", "--"]
CMD ["your-program", "--your", "args"]
```

zini exits with the exit code of its child (or `128 + signal` if the child was
killed by a signal).

### Options

| Option        | Description                                                       |
|---------------|-------------------------------------------------------------------|
| `-v`, `--version` | Show version and exit (only when it is the sole argument).    |
| `-h`          | Show help and exit.                                               |
| `-s`          | Register as a process subreaper (requires Linux >= 3.4).          |
| `-p SIGNAL`   | Trigger `SIGNAL` when the parent dies, e.g. `-p SIGKILL`.         |
| `-v`          | More verbose output. Repeat up to 3 times.                        |
| `-w`          | Print a warning when processes are reaped.                        |
| `-g`          | Send signals to the child's process group, not just the child.    |
| `-e EXIT_CODE`| Remap `EXIT_CODE` (0–255) to 0. Can be repeated.                  |
| `-l`          | Show license and exit.                                            |

### Environment variables

| Variable                  | Effect                                              |
|---------------------------|-----------------------------------------------------|
| `TINI_SUBREAPER`          | If set, register as a subreaper (same as `-s`).     |
| `TINI_KILL_PROCESS_GROUP` | If set, signal the child's process group (same as `-g`). |
| `TINI_VERBOSITY`          | Set the verbosity level (default: 1).               |

## File watching / hot reload (optional)

A feature beyond tini: zini can watch files and **restart (or signal) the
supervised app when they change** — useful for hot-reloading config or rotated
TLS certificates for apps that don't reload on their own. It is entirely
opt-in: with no `--watch`, zini behaves exactly like tini.

```sh
# Restart the app whenever the cert or config changes:
zini --watch /etc/tls/tls.crt --watch /etc/app/config.yaml -- myapp

# Or just send SIGHUP and let the app reload itself:
zini --watch /etc/app/config.yaml --on-change=signal --reload-signal=SIGHUP -- myapp
```

| Flag | Default | Description |
|------|---------|-------------|
| `-W`, `--watch PATH` | — | Watch `PATH`; repeatable. Any `--watch` enables the feature. |
| `--on-change=restart\|signal` | `restart` | Restart the child, or just signal it. |
| `--stop-signal=SIGNAL` | `SIGTERM` | Signal used to stop the child on restart. |
| `--restart-grace=SECONDS` | `10` | Wait this long for a clean stop before `SIGKILL`. |
| `--reload-signal=SIGNAL` | `SIGHUP` | Signal sent in `--on-change=signal` mode. |
| `--debounce=MS` | `200` | Coalesce a burst of changes into one action. |

Every flag also has an environment variable, so a container with a fixed
entrypoint can enable/configure watching without changing its command — just set
env vars:

| Env var | Equivalent flag |
|---------|-----------------|
| `ZINI_WATCH` | `--watch` (`:`-separated list; added to any `--watch` paths) |
| `ZINI_ON_CHANGE` | `--on-change` (`restart`\|`signal`) |
| `ZINI_STOP_SIGNAL` | `--stop-signal` |
| `ZINI_RESTART_GRACE` | `--restart-grace` (seconds) |
| `ZINI_RELOAD_SIGNAL` | `--reload-signal` |
| `ZINI_DEBOUNCE` | `--debounce` (ms) |

For scalar settings the env var wins over the flag (so the deployment env can
override a baked-in default). Example — same image, behavior chosen by env only:

```dockerfile
ENTRYPOINT ["/usr/local/bin/zini", "--"]
CMD ["myapp"]
# then at deploy time:  -e ZINI_WATCH=/etc/tls/tls.crt:/etc/app/config.yaml
```

How it works and what it handles:

- Each `--watch` target (a **file, directory, or symlink**, which must exist when
  zini starts) gets one inotify watch. zini doesn't care *what* changed — any
  event on a watched target triggers a reload.
- inotify follows symlinks and watches the real target, so a **symlinked config
  or cert** is watched at its real file — an in-place write **through** the link
  (e.g. editing in an editor) is caught directly.
- When the watched inode goes away — **atomic replacement** (temp file + rename)
  or a **Kubernetes Secret/ConfigMap rotation** (which swaps a symlink and
  deletes the old directory) — inotify drops the watch; zini re-adds it on the
  same path, re-following the symlink to the new file. No path parsing or k8s
  special-casing is involved.
- If a re-add fails because the path is momentarily broken (a non-atomic update
  that leaves a dangling symlink), the watch isn't lost: zini marks it and
  retries on the next reload, so it recovers once the path is valid again. (A
  broken config that the app actually needs is also self-correcting: the app
  fails on restart and zini exits with its code, surfacing the problem.)
- A **directory** target reloads on any change to a file directly inside it
  (one level, non-recursive).
- **Exit model is unchanged from tini:** if the app exits on its own (crash or
  normal exit), zini exits with the app's code. Only a watched-file change
  triggers a respawn.
- In `restart` mode zini sends `--stop-signal`, waits up to `--restart-grace`,
  then `SIGKILL`s if needed, and respawns the original command.

## Building

Requires [Zig 0.16.0](https://ziglang.org/download/). The program is Linux-only;
when building from a non-Linux host the default target cross-compiles to Linux.

```sh
zig build                 # build for Linux (static, no libc)
zig build test            # run unit tests (run on the host)
zig build release         # static ReleaseSmall binaries for x86_64 + aarch64
zig build run -- echo hi  # build and run
```

A `Makefile` wraps these for convenience:

```sh
make             # build
make test        # unit tests
make release     # both-arch static release binaries -> zig-out/bin/
make fmt         # format sources
make lint        # zlint (if installed) + formatting check
make ci          # lint + build + release + test (local gate)
make docker      # build the production image + the test image
make e2e-test    # build images and run the in-container + host-driven suites
make bench       # profile the supervision loop (debug build) in a container
make clean
```

`make lint`/`make ci` run [`zlint`](https://github.com/DonIsaac/zlint) when it's
installed (and skip it with a hint otherwise), plus `zig fmt --check`.

The release binaries are fully static (`file zig-out/bin/zini-x86_64-linux`
reports `statically linked`).

## Testing

- **Unit tests** (`zig build test`) cover the pure logic: argument parsing,
  the exit-code remap bitfield, signal-name lookup, and environment parsing.
- **Integration tests** (`make e2e-test`) build a test image
  ([`Dockerfile.tests`](Dockerfile.tests)) that bakes in the binaries, the
  in-container [`scripts/`](scripts/) (test children + suite), and a consistent
  set of `/fix/*` fixtures — so the host scripts just drive scenarios. Three
  suites:
  - [`scripts/integration.sh`](scripts/integration.sh) runs *inside* the
    container with zini as PID 1: exit-code passthrough, signal-to-exit-code
    mapping (`128 + signal`), exit-code remapping, the not-PID-1 warning, signal
    forwarding, and **zombie reaping** (orphan a process and check `/proc` shows
    no leftover `Z`-state processes).
  - [`test/docker_signal_test.sh`](test/docker_signal_test.sh) drives the real
    `docker stop` scenario from the *host*: SIGTERM to PID-1 zini must be
    forwarded so the container exits 0 promptly (with a negative control where
    the child ignores SIGTERM and docker falls back to SIGKILL → 137).
  - [`test/watch_test.sh`](test/watch_test.sh) exercises the file-watch feature
    (watch options set via `ZINI_*` env): in-place write, temp+rename, k8s
    rotation, debounce, signal mode, the self-exit model, grace→SIGKILL, watch
    recovery, and the `-W` flag path.

## License

MIT. See [LICENSE](LICENSE). zini is a derivative work of tini, which is also
MIT licensed.
