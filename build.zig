const std = @import("std");

const version = "0.1.0";

pub fn build(b: *std.Build) void {
    // zini only runs on Linux, so when building from a non-Linux host we default
    // to cross-compiling to Linux (keeping the host CPU arch). `-Dtarget` overrides.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Build-time options (exposed to the code as `@import("build_options")`).
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Primary executable.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = false,
        .strip = optimize != .Debug,
    });
    exe_mod.addOptions("build_options", options);
    exe_mod.addAnonymousImport("license", .{ .root_source_file = b.path("LICENSE") });

    const exe = b.addExecutable(.{
        .name = "zini",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // `zig build run` — handy for quick local invocation.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zini");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests live in src/zini.zig. These cover the pure
    // logic (arg/env parsing, bitfield, signal-name lookup) and must *run*, so we
    // build them for the host (native) target. The exercised paths never invoke a
    // real Linux syscall, so this is safe to run on a non-Linux dev machine too.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zini.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = false,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addAnonymousImport("license", .{ .root_source_file = b.path("LICENSE") });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build release` — static ReleaseSmall binaries for both Linux arches.
    const release_step = b.step("release", "Build static release binaries (x86_64 + aarch64 Linux)");
    const arches = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64 };
    for (arches) |arch| {
        const rt = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux });
        const rel_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = rt,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .link_libc = false,
            .strip = true,
        });
        rel_mod.addOptions("build_options", options);
        rel_mod.addAnonymousImport("license", .{ .root_source_file = b.path("LICENSE") });
        const rel_exe = b.addExecutable(.{
            .name = "zini",
            .root_module = rel_mod,
        });
        const install = b.addInstallArtifact(rel_exe, .{
            .dest_sub_path = b.fmt("zini-{s}-linux", .{@tagName(arch)}),
        });
        release_step.dependOn(&install.step);
    }
}
