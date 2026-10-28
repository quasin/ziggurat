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

    // librats is vendored per target triple, because a static C++ archive only
    // links into a binary of the architecture it was compiled for:
    // vendor/librats/<arch>-<os>-<abi>/{include,librats.a}. scripts/fetch-librats.sh
    // writes these; nothing under vendor/ is committed.
    const r = target.result;
    const triple = b.fmt("{s}-{s}-{s}", .{
        @tagName(r.cpu.arch),
        @tagName(r.os.tag),
        @tagName(r.abi),
    });
    const vendor_dir = b.fmt("vendor/librats/{s}", .{triple});
    const librats_archive = b.fmt("{s}/librats.a", .{vendor_dir});

    // Fail with the fix instead of a raw linker error when the target was never
    // vendored (an empty archive path would otherwise reach the linker).
    std.Io.Dir.cwd().access(b.graph.io, librats_archive, .{}) catch {
        std.debug.panic(
            "librats is not vendored for {s} — run `bash scripts/fetch-librats.sh {s}`, then rebuild",
            .{ triple, triple },
        );
    };

    const librats_include = b.path(b.fmt("{s}/include", .{vendor_dir}));

    // The version lives in build.zig.zon only; it reaches the code as a
    // generated `build_options` module so no source file repeats it.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);

    // librats exposes a C ABI at librats/bindings/rats.h; the headers around it
    // are C++. Zig 0.17 has no inline @cImport, so they are translated into a
    // module from src/c.h and imported as `c`.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(librats_include);

    const exe = b.addExecutable(.{
        .name = "ziggurat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts.createModule() },
                .{ .name = "c", .module = translate_c.createModule() },
            },
        }),
    });

    exe.root_module.addObjectFile(b.path(librats_archive));
    exe.root_module.addIncludePath(librats_include);
    exe.root_module.link_libc = true;
    // librats.a is compiled by `zig c++`, i.e. against Zig's bundled libc++ —
    // the same C++ runtime this link pulls in. That is what makes the archive
    // portable across targets instead of tied to a system libstdc++ ABI.
    exe.root_module.link_libcpp = true;

    b.installArtifact(exe);

    // `zig build dist` builds all three published targets into
    // zig-out/<triple>/ziggurat in ReleaseSafe (panic messages kept, undefined
    // behaviour not exploited). Each is a separate executable, because a build
    // graph artifact has exactly one target.
    const dist_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "riscv64-linux-gnu" };
    const dist_step = b.step("dist", "Build ziggurat for linux x86_64/aarch64/riscv64");
    for (dist_targets) |dt| {
        const dt_target = b.resolveTargetQuery(.{ .cpu_arch = dtArch(dt), .os_tag = .linux, .abi = .gnu });
        const dist_exe = b.addExecutable(.{
            .name = "ziggurat",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = dt_target,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &.{
                    .{ .name = "build_options", .module = opts.createModule() },
                    .{ .name = "c", .module = distTranslateC(b, dt_target, dt).createModule() },
                },
            }),
        });
        dist_exe.root_module.link_libc = true;
        dist_exe.root_module.link_libcpp = true;
        dist_exe.root_module.addObjectFile(b.path(b.fmt("vendor/librats/{s}/librats.a", .{dt})));
        dist_exe.root_module.addIncludePath(b.path(b.fmt("vendor/librats/{s}/include", .{dt})));
        const install = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = dt } },
        });
        dist_step.dependOn(&install.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ziggurat");
    run_step.dependOn(&run_cmd.step);

    // Tests live in `test` blocks next to the code they cover; the executable's
    // root module is the only module, so one test artifact covers the project.
    // It links librats too, so version reporting is tested against the real
    // library rather than a stub.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn dtArch(triple: []const u8) std.Target.Cpu.Arch {
    if (std.mem.startsWith(u8, triple, "aarch64")) return .aarch64;
    if (std.mem.startsWith(u8, triple, "riscv64")) return .riscv64;
    return .x86_64;
}

fn distTranslateC(b: *std.Build, target: std.Build.ResolvedTarget, triple: []const u8) *std.Build.Step.TranslateC {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    tc.addIncludePath(b.path(b.fmt("vendor/librats/{s}/include", .{triple})));
    return tc;
}
