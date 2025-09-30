const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;
const LazyPath = std.Build.LazyPath;
const build_util = @import("utils/build_util.zig");
pub const RunProtocStep = build_util.RunProtocStep;

const PROTOC_VERSION = build_util.PROTOC_VERSION;

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "zig-protobuf",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),

        .linkage = .static,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = build_util.buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const test_step = b.step("test", "Run library tests");

    const tests = [_]*std.Build.Step.Compile{
        b.addTest(.{ .name = "protobuf", .root_module = module }),
        b.addTest(.{
            .name = "bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "alltypes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/alltypes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "fixedsizes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_fixedsizes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "varints",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_varints.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "json",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_json.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "FullName",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/FullName.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
    };

    const convertStep = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("tests/.generated"),
        .source_files = &.{"tests/protos_for_test/generated_in_ci.proto"},
        .include_directories = &.{"tests/protos_for_test"},
    });

    const convertStep2 = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("tests/generated"),
        .source_files = &.{ "tests/protos_for_test/all.proto", "tests/protos_for_test/whitespace-in-name.proto" },
        .include_directories = &.{"tests/protos_for_test"},
    });

    for (tests) |test_item| {
        if (!std.mem.eql(u8, "protobuf", test_item.name)) {
            test_item.root_module.addImport("protobuf", module);
        }
        test_item.root_module.addImport("protobuf", module);

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const run_main_tests = b.addRunArtifact(test_item);

        test_item.step.dependOn(&convertStep.step);
        test_item.step.dependOn(&convertStep2.step);

        test_step.dependOn(&run_main_tests.step);
    }

    const wd = try build_util.getProtocInstallDir(std.heap.page_allocator, PROTOC_VERSION);

    const bootstrap = b.step("bootstrap", "run the generator over its own sources");

    const bootstrapConversion = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("bootstrapped-generator"),
        .source_files = &.{
            b.pathJoin(&.{ wd, "include/google/protobuf/compiler/plugin.proto" }),
            b.pathJoin(&.{ wd, "include/google/protobuf/descriptor.proto" }),
        },
        .include_directories = &.{},
    });

    bootstrap.dependOn(&bootstrapConversion.step);
}
