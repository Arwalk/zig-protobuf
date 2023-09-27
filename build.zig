const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig-protobuf",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/protobuf.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const module = b.addModule("protobuf", .{
        .source_file = .{ .path = "src/protobuf.zig" },
    });

    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "bootstrapped-generator/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(&lib.step);
    exe.addModule("protobuf", module);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const test_step = b.step("test", "Run library tests");

    var tests = [_]*std.build.LibExeObjStep{
        b.addTest(.{
            .name = "protobuf",
            .root_source_file = .{ .path = "src/protobuf.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "tests",
            .root_source_file = .{ .path = "tests/tests.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "alltypes",
            .root_source_file = .{ .path = "tests/alltypes.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "integration",
            .root_source_file = .{ .path = "tests/integration.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "fixedsizes",
            .root_source_file = .{ .path = "tests/tests_fixedsizes.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "varints",
            .root_source_file = .{ .path = "tests/tests_varints.zig" },
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "FullName",
            .root_source_file = .{ .path = "bootstrapped-generator/FullName.zig" },
            .target = target,
            .optimize = optimize,
        }),
    };

    for (tests) |test_item| {
        test_item.addModule("protobuf", module);

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const run_main_tests = b.addRunArtifact(test_item);
        test_step.dependOn(&run_main_tests.step);
    }
}
