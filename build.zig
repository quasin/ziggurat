const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to the portable x86_64 baseline instead of the host CPU: Zig's
    // default is `native`, which bakes in AVX-512 and friends and dies with
    // SIGILL on any older machine the binary is copied to. Pass `-Dcpu=native`
    // for a machine-local binary.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    // The version lives in build.zig.zon only; it reaches the code as a
    // generated `build_options` module so no source file repeats it.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe = b.addExecutable(.{
        .name = "ziggurat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ziggurat");
    run_step.dependOn(&run_cmd.step);

    // Tests live in `test` blocks next to the code they cover; the executable's
    // root module is the only module, so one test artifact covers the project.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
