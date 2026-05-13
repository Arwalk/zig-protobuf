const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("jsoncpp", .{});

    const jsoncpp = b.addLibrary(.{
        .name = "jsoncpp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });

    jsoncpp.root_module.addIncludePath(upstream.path("include"));
    jsoncpp.root_module.addCSourceFiles(.{
        .root = upstream.path("src/lib_json"),
        .files = &.{
            "json_reader.cpp",
            "json_value.cpp",
            "json_writer.cpp",
        },
        .language = .cpp,
    });
    jsoncpp.installHeadersDirectory(
        upstream.path("include/json"),
        "json",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(jsoncpp);
}
