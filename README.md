# zini

**zini** is the simplest `init` you could think of, for containers — it spawns a
single child process, forwards signals to it, and reaps zombie processes so that
running as PID 1 inside a container behaves correctly.

## Origin

zini is a **rewrite of [tini](https://github.com/krallin/tini) from C to
[Zig](https://ziglang.org/)**. tini ("the simplest init you could think of") is
written in C by Thomas Orozco and contributors. This project ports its logic
faithfully to Zig while producing a **statically linked, libc-free** binary
(every operation goes through raw Linux syscalls via `std.os.linux` / `std.posix`).

Behavior, command-line flags, environment variables, and exit-code semantics
match tini, so zini is intended to be a drop-in replacement. The original
`TINI_*` environment variable names are kept on purpose for compatibility.

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
COPY zini /usr/local/bin/zini
ENTRYPOINT ["/usr/local/bin/zini", "--"]
CMD ["your-program", "--your", "args"]
```

zini exits with the exit code of its child (or `128 + signal` if the child was
killed by a signal).

### Options

| Option        | Description                                                       |
|---------------|-------------------------------------------------------------------|
| `--version`   | Show version and exit (only when it is the sole argument).         |
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
make            # build
make test       # unit tests
make release    # both-arch static release binaries -> zig-out/bin/
make fmt        # format sources
make fmt-check  # check formatting
make docker-test # build a Linux image and run the integration suite
make clean
```

The release binaries are fully static (`file zig-out/bin/zini-x86_64-linux`
reports `statically linked`).

## Testing

- **Unit tests** (`zig build test`) cover the pure logic: argument parsing,
  the exit-code remap bitfield, signal-name lookup, and environment parsing.
- **Integration tests** (`make docker-test`) run two suites:
  - [`test/integration.sh`](test/integration.sh) runs *inside* the container
    with zini as PID 1 (the entrypoint). It verifies exit-code passthrough,
    signal-to-exit-code mapping (`128 + signal`), exit-code remapping, the
    not-PID-1 warning, signal forwarding, and **zombie reaping** — the last by
    orphaning a process so the kernel re-parents it to PID 1 (zini) and checking
    `/proc` shows no leftover `Z`-state processes.
  - [`test/docker_signal_test.sh`](test/docker_signal_test.sh) drives the real
    `docker stop` scenario from the *host*: SIGTERM to PID-1 zini must be
    forwarded so the container exits 0 promptly (with a negative control where
    the child ignores SIGTERM and docker falls back to SIGKILL → 137).

## License

MIT. See [LICENSE](LICENSE). zini is a derivative work of tini, which is also
MIT licensed.
