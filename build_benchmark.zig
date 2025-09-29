const std = @import("std");
const build_util = @import("build_util.zig");
pub var download_mutex = std.Thread.Mutex{};

const PROTOC_VERSION = "23.4";

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

    // Create the protobuf module
    const protobuf_module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the protoc generator (needed for benchmark data generation)
    const generator = buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    });

    try buildBenchmark(b, protobuf_module, target, optimize, generator);
}

fn buildBenchmark(b: *std.Build, protobuf_module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, generator: *std.Build.Step.Compile) !void {

    // ZBench setup
    const zbench_dir_rel = try std.fs.path.join(b.allocator, &.{ ".zig-cache", "zbench", "zBench-0.11.2" });
    try std.fs.cwd().makePath(zbench_dir_rel);
    defer b.allocator.free(zbench_dir_rel);

    const zbench_dir = try std.fs.cwd().realpathAlloc(b.allocator, zbench_dir_rel);
    defer b.allocator.free(zbench_dir);

    const zbench_zig = try std.fs.path.join(b.allocator, &.{ zbench_dir, "zbench.zig" });
    defer b.allocator.free(zbench_zig);

    if (!build_util.fileExists(zbench_zig)) {
        try downloadZBench(b.allocator, ".zig-cache/zbench");
    }

    const zbench_module = b.addModule("zbench", .{
        .root_source_file = b.path(".zig-cache/zbench/zBench-0.11.2/zbench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Benchmark step
    const benchmark_step = b.step("benchmark", "Run benchmarks");

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/benchmarks.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark_exe.root_module.addImport("zbench", zbench_module);
    benchmark_exe.root_module.addImport("protobuf", protobuf_module);
    benchmark_step.dependOn(&b.addRunArtifact(benchmark_exe).step);

    // Protoc generation for benchmarks
    const convertForBenchmarkStep = build_util.RunProtocStep.createWithGenerator(b, generator, .{
        .destination_directory = b.path("benchmark/generated"),
        .source_files = &.{ "tests/protos_for_test/opentelemetry/proto/metrics/v1/metrics.proto", "tests/protos_for_test/opentelemetry/proto/common/v1/common.proto" },
        .include_directories = &.{"tests/protos_for_test"},
    });
    benchmark_exe.step.dependOn(&convertForBenchmarkStep.step);

    // Generate dataset step
    const generate_dataset_step = b.step("generate-dataset", "Generate benchmark dataset");

    var convertForDatasetStep = build_util.RunProtocStep.createWithGenerator(b, generator, .{
        .destination_directory = b.path("benchmark/generated"),
        .source_files = &.{ "tests/protos_for_test/benchmark_data.proto", "tests/protos_for_test/opentelemetry/proto/metrics/v1/metrics.proto", "tests/protos_for_test/opentelemetry/proto/common/v1/common.proto" },
        .include_directories = &.{"tests/protos_for_test"},
    });

    const generate_dataset_exe = b.addExecutable(.{
        .name = "generate_dataset",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/generate_dataset.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    generate_dataset_exe.root_module.addImport("protobuf", protobuf_module);
    generate_dataset_exe.step.dependOn(&convertForDatasetStep.step);
    benchmark_step.dependOn(&convertForDatasetStep.step);

    const run_generate = b.addRunArtifact(generate_dataset_exe);

    if (b.args) |args| {
        run_generate.addArgs(args);
    }

    generate_dataset_step.dependOn(&run_generate.step);
}

pub const GenOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub fn buildGenerator(b: *std.Build, opt: GenOptions) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bootstrapped-generator/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);
    b.installArtifact(exe);
    return exe;
}

// ZBench utilities
pub fn downloadZBench(
    allocator: std.mem.Allocator,
    target_cache_dir: []const u8,
) !void {
    download_mutex.lock();
    defer download_mutex.unlock();
    const download_url = "https://github.com/hendriknielaender/zBench/archive/refs/tags/v0.11.2.zip";
    build_util.ensureCanDownloadFiles(allocator);
    build_util.ensureCanUnzipFiles(allocator);
    const download_dir = try std.fs.path.join(allocator, &.{ target_cache_dir, "zbench" });
    defer allocator.free(download_dir);
    std.fs.cwd().makePath(download_dir) catch @panic(download_dir);
    std.debug.print("download_dir: {s}\n", .{download_dir});

    const zip_target_file = try std.fs.path.join(allocator, &.{ download_dir, "zbench.zip" });
    defer allocator.free(zip_target_file);
    build_util.downloadFile(allocator, zip_target_file, download_url) catch @panic(zip_target_file);

    build_util.unzipFile(allocator, zip_target_file, target_cache_dir) catch @panic(zip_target_file);
}
