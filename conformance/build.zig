const std = @import("std");
const zig_protobuf = @import("zig_protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_protobuf_dep = b.dependency("zig_protobuf", .{ .target = target, .optimize = optimize });
    const protobuf_module = zig_protobuf_dep.module("protobuf");
    const protoc_gen_zig = zig_protobuf_dep.artifact("protoc-gen-zig");

    const protobuf_pkg_dep = b.dependency("protobuf_pkg", .{ .target = target, .optimize = optimize });
    const upstream = protobuf_pkg_dep.builder.dependency("protobuf", .{});
    const protoc = protobuf_pkg_dep.artifact("protoc");
    const runner_artifact = protobuf_pkg_dep.artifact("conformance_test_runner");

    // Regenerate Zig bindings using source-built protoc.
    // Run with: zig build generate
    const gen_zig = zig_protobuf.RunProtocStep.createWithGenerator(b, protoc_gen_zig, .{
        .source_files = &.{
            b.path("protos/conformance.proto"),
            b.path("protos/test_messages_proto3.proto"),
        },
        .include_directories = &.{ b.path("protos"), upstream.path("src") },
        .destination_directory = b.path("generated"),
        .protoc = protoc,
    });
    b.step("generate", "Regenerate Zig bindings for conformance protos").dependOn(&gen_zig.step);

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
    run_cmd.addArgs(&.{ "--enforce_recommended", "--maximum_edition", "2024", "--output_dir", "out" });
    run_cmd.addArtifactArg(testee);
    b.step("conformance-run", "Run the protobuf conformance test suite").dependOn(&run_cmd.step);
}
