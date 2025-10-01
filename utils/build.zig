const std = @import("std");
const build_util = @import("build_util.zig");
const RunProtocStep = build_util.RunProtocStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const opts = .{ .target = target, .optimize = optimize };
    const zbench_module = b.dependency("zbench", opts).module("zbench");

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const protobuf_module = b.addModule("protobuf", .{
        .root_source_file = b.path("../src/protobuf.zig"),
    });

    const generator = buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    }, protobuf_module);

    benchmark_exe.root_module.addImport("zbench", zbench_module);
    benchmark_exe.root_module.addImport("protobuf", protobuf_module);

    b.installArtifact(benchmark_exe);

    const benchmark_run = b.step("benchmark", "Run the app");

    const run_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_run.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    // Protoc generation for benchmarks
    const convertForBenchmarkStep = RunProtocStep.createWithGenerator(b, generator, .{
        .destination_directory = b.path("src/generated"),
        .source_files = &.{ "../tests/protos_for_test/opentelemetry/proto/metrics/v1/metrics.proto", "../tests/protos_for_test/opentelemetry/proto/common/v1/common.proto" },
        .include_directories = &.{"../tests/protos_for_test"},
    });
    benchmark_exe.step.dependOn(&convertForBenchmarkStep.step);

    // Generate dataset step
    const generate_dataset_step = b.step("generate-dataset", "Generate benchmark dataset");

    var convertForDatasetStep = RunProtocStep.createWithGenerator(b, generator, .{
        .destination_directory = b.path("src/generated"),
        .source_files = &.{ "../tests/protos_for_test/benchmark_data.proto", "../tests/protos_for_test/opentelemetry/proto/metrics/v1/metrics.proto", "../tests/protos_for_test/opentelemetry/proto/common/v1/common.proto" },
        .include_directories = &.{"../tests/protos_for_test"},
    });

    const generate_dataset_exe = b.addExecutable(.{
        .name = "generate_dataset",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_dataset.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    generate_dataset_exe.root_module.addImport("protobuf", protobuf_module);
    generate_dataset_exe.step.dependOn(&convertForDatasetStep.step);
    benchmark_exe.step.dependOn(&convertForDatasetStep.step);

    const run_generate = b.addRunArtifact(generate_dataset_exe);

    if (b.args) |args| {
        run_generate.addArgs(args);
    }

    generate_dataset_step.dependOn(&run_generate.step);
}

pub fn buildGenerator(b: *std.Build, opt: build_util.GenOptions, protobuf_module: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../bootstrapped-generator/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });

    exe.root_module.addImport("protobuf", protobuf_module);
    b.installArtifact(exe);
    return exe;
}
