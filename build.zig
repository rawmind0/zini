const std = @import("std");

const name = "zini";

pub fn build(b: *std.Build) void {
    // zini only runs on Linux, so when building from a non-Linux host we default
    // to cross-compiling to Linux (keeping the host CPU arch). `-Dtarget` overrides.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Built-in profiler: default on in Debug, off otherwise; `-Dprofile` overrides.
    const profile = b.option(bool, "profile", "Build the in-process profiler into the binary") orelse
        (optimize == .Debug);
    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";

    // Build-time options (exposed to the code as `@import("build_options")`).
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "profile", profile);

    const license = b.path("LICENSE");

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
    exe_mod.addAnonymousImport("license", .{ .root_source_file = license });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // `zig build run` — handy for quick local invocation.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests aggregated in src/tests.zig. Built for the
    // host (native) target so they run on a non-Linux dev machine too; the
    // exercised code paths never issue a real Linux syscall (silent Logger).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = false,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addAnonymousImport("license", .{ .root_source_file = license });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build release` — static ReleaseSmall binaries for both Linux arches.
    // The profiler is always compiled out of release builds.
    const rel_options = b.addOptions();
    rel_options.addOption([]const u8, "version", version);
    rel_options.addOption(bool, "profile", false);

    const release_step = b.step("release", "Build static release linux binaries (x86_64 + aarch64)");
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
        rel_mod.addOptions("build_options", rel_options);
        rel_mod.addAnonymousImport("license", .{ .root_source_file = license });
        const rel_exe = b.addExecutable(.{
            .name = name,
            .root_module = rel_mod,
        });
        const docker_arch = switch (arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            else => "",
        };
        const install = b.addInstallArtifact(rel_exe, .{
            .dest_sub_path = b.fmt("{s}-linux-{s}", .{ name, docker_arch }),
        });
        release_step.dependOn(&install.step);
    }
}
