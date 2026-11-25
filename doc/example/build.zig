//! A project that uses zig-protobuf, as any consumer would. The README shows parts of it: see
//! `doc/readme_snippets.zig` for the `tag::` comments.

const std = @import("std");
// tag::gen-proto-import[]
const protobuf = @import("protobuf");
// end::gen-proto-import[]

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // tag::dependency[]
    // first create a build for the dependency
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    // and lastly use the dependency as a module
    exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
    // end::dependency[]

    b.installArtifact(exe);

    // tag::gen-proto[]
    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    // The generator runs during the build: it is built for the host, not for `target`.
    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, b.graph.host, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            b.path("proto/project.proto"),
        },
        .include_directories = &.{},
        // Optional LazyPath to `protoc`. If null, zig-protobuf downloads Google's release of
        // the compiler. See "Building protoc from source" to avoid this binary.
        .protoc = null,
        // Preserve unknown fields during binary decode/encode round trips.
        // Defaults to false.
        .preserve_unknown_fields = false,
    });

    gen_proto.dependOn(protoc_step.step);
    // end::gen-proto[]

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the example").dependOn(&run.step);

    const check_output = b.addRunArtifact(exe);
    check_output.expectStdOutEqual(@embedFile("expected_output.txt"));
    b.step("test", "Check the output of the example").dependOn(&check_output.step);
}
