const std = @import("std");
const zig_protobuf = @import("zig_protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_protobuf_dep = b.dependency("zig_protobuf", .{ .target = target, .optimize = optimize });
    const protobuf_module = zig_protobuf_dep.module("protobuf");
    const protoc_gen_zig = zig_protobuf_dep.artifact("protoc-gen-zig");

    const protoc_source_dep = zig_protobuf_dep.builder.dependency("protoc_source", .{ .target = target, .optimize = optimize });
    const upstream = protoc_source_dep.builder.dependency("protobuf", .{});
    const protoc = protoc_source_dep.artifact("protoc");
    const runner_artifact = buildRunner(b, target, optimize, protoc_source_dep, upstream);

    // Regenerate Zig bindings using source-built protoc.
    // Run with: zig build generate
    const gen_zig = zig_protobuf.RunProtocStep.create(b, target, .{
        .source_files = &.{
            b.path("protos/conformance.proto"),
            b.path("protos/test_messages_proto3.proto"),
            b.path("protos/test_messages_proto2.proto"),
            b.path("protos/test_messages_edition2023.proto"),
            b.path("protos/test_messages_proto2_editions.proto"),
            b.path("protos/test_messages_proto3_editions.proto"),
            b.path("protos/test_messages_edition_unstable.proto"),
        },
        .include_directories = &.{ b.path("protos"), upstream.path("src") },
        .destination_directory = b.path("generated"),
        .generator = protoc_gen_zig,
        .protoc = protoc.getEmittedBin(),
        .preserve_unknown_fields = true,
        // The unstable edition test messages use `edition = "UNSTABLE"`.
        .experimental_editions = true,
    });

    // Instruct zig build system to first build protoc before trying to generate the .pb.zig!
    gen_zig.step.dependOn(&protoc.step);

    b.step("generate", "Regenerate Zig bindings for conformance protos").dependOn(gen_zig.step);

    // Testee binary — uses pre-generated bindings from conformance/generated/.
    const testee = b.addExecutable(.{
        .name = "conformance-testee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    testee.root_module.addImport("protobuf", protobuf_module);

    const install_testee = b.addInstallArtifact(testee, .{});
    b.step("conformance", "Build the conformance testee binary").dependOn(&install_testee.step);

    // conformance_test_runner
    const install_runner = b.addInstallArtifact(runner_artifact, .{});
    b.step("conformance-runner", "Build the protobuf conformance_test_runner").dependOn(&install_runner.step);

    // Run the full conformance suite.
    const run_cmd = b.addRunArtifact(runner_artifact);
    run_cmd.addArgs(&.{
        "--enforce_recommended",
        "--maximum_edition",
        "2026",
        "--output_dir",
        "out",
        "--failure_list",
        "out/failing_tests.txt",
    });
    run_cmd.addArtifactArg(testee);
    b.step("conformance-run", "Run the protobuf conformance test suite").dependOn(&run_cmd.step);
}

/// Builds the conformance_test_runner of protobuf.
fn buildRunner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    protoc_source_dep: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const abseil_dep = protoc_source_dep.builder.dependency("abseil", .{ .target = target, .optimize = optimize });
    const jsoncpp_dep = b.dependency("jsoncpp", .{ .target = target, .optimize = optimize });

    // Generate .pb.cc/.pb.h files needed for conformance_test_runner.
    // Order: -I src first so test_messages_proto3.proto resolves as
    //        "google/protobuf/test_messages_proto3.proto" (not "src/google/...").
    const gen = b.addRunArtifact(protoc_source_dep.artifact("protoc"));
    gen.addPrefixedDirectoryArg("-I", upstream.path("src"));
    gen.addPrefixedDirectoryArg("-I", upstream.path(""));
    const gen_out = gen.addPrefixedOutputDirectoryArg("--cpp_out=", "conformance_pb_gen");
    gen.addFileArg(upstream.path("conformance/conformance.proto"));
    gen.addFileArg(upstream.path("conformance/test_protos/test_messages_edition2023.proto"));
    gen.addFileArg(upstream.path("conformance/test_protos/test_messages_edition_unstable.proto"));
    gen.addFileArg(upstream.path("editions/golden/test_messages_proto2_editions.proto"));
    gen.addFileArg(upstream.path("editions/golden/test_messages_proto3_editions.proto"));
    gen.addFileArg(upstream.path("src/google/protobuf/test_messages_proto2.proto"));
    gen.addFileArg(upstream.path("src/google/protobuf/test_messages_proto3.proto"));

    const runner = b.addExecutable(.{
        .name = "conformance_test_runner",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    runner.root_module.linkLibrary(protoc_source_dep.artifact("libprotoc"));
    runner.root_module.linkLibrary(protoc_source_dep.artifact("libprotobuf"));
    runner.root_module.linkLibrary(protoc_source_dep.artifact("utf8_range"));
    runner.root_module.linkLibrary(protoc_source_dep.artifact("upb"));
    runner.root_module.linkLibrary(abseil_dep.artifact("abseil"));
    runner.root_module.linkLibrary(jsoncpp_dep.artifact("jsoncpp"));
    // Headers from conformance/ directory (not installed, accessed directly).
    runner.root_module.addIncludePath(upstream.path("conformance"));
    // Generated pb.h files (conformance/conformance.pb.h etc.).
    runner.root_module.addIncludePath(gen_out);
    // conformance runner C++ sources
    runner.root_module.addCSourceFiles(.{
        .root = upstream.path("conformance"),
        .files = conformance_runner_srcs,
        .language = .cpp,
    });
    // Generated pb.cc files
    for (conformance_generated_srcs) |file| {
        runner.root_module.addCSourceFile(.{
            .file = gen_out.path(b, file),
            .language = .cpp,
        });
    }
    return runner;
}

const conformance_generated_srcs: []const []const u8 = &.{
    "conformance/conformance.pb.cc",
    "conformance/test_protos/test_messages_edition2023.pb.cc",
    "conformance/test_protos/test_messages_edition_unstable.pb.cc",
    "editions/golden/test_messages_proto2_editions.pb.cc",
    "editions/golden/test_messages_proto3_editions.pb.cc",
    "google/protobuf/test_messages_proto2.pb.cc",
    "google/protobuf/test_messages_proto3.pb.cc",
};

const conformance_runner_srcs: []const []const u8 = &.{
    "conformance_test_main.cc",
    "conformance_test.cc",
    "conformance_test_runner.cc",
    "binary_json_conformance_suite.cc",
    "binary_wireformat.cc",
    "failure_list_trie_node.cc",
    "fork_pipe_runner.cc",
    "test_manager.cc",
    "testee.cc",
    "text_format_conformance_suite.cc",
};
