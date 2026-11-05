//! A project that uses zig-protobuf with a protoc built from source, as any consumer would. It is
//! not part of the build of zig-protobuf since this would fetch the sources of protoc for everyone.

const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protobuf_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });

    // No include directory for the well-known types: protoc finds them on its own.
    const generate = protobuf.RunProtocStep.create(b, target, .{
        .destination_directory = b.path(".generated"),
        .generator = protobuf_dep.artifact("protoc-gen-zig"),
        .protoc = protobuf.protocFromSource(protobuf_dep.builder),
        .source_files = &.{b.path("protos/event.proto")},
        .include_directories = &.{b.path("protos")},
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
    tests.step.dependOn(generate.step);

    b.step("test", "Generate code with a protoc built from source and test it")
        .dependOn(&b.addRunArtifact(tests).step);
}
