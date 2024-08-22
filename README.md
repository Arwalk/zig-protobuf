# zig-protobuf

-------

## Welcome!

This is an implementation of google Protocol Buffers version 3 in Zig.

Protocol Buffers is a serialization protocol so systems, from any programming language or platform, can exchange data reliably.

Protobuf's strength lies in a generic codec paired with user-defined "messages" that will define the true nature of the data encoded.

Messages are usually mapped to a native language's structure/class definition thanks to a language-specific generator associated with an implementation.

Zig's compile-time evaluation becomes extremely strong and useful in this context: because the structure (a message) has to be known beforehand, the generic codec can leverage informations, at compile time, of the message and it's nature. This allows optimizations that are hard to get as easily in any other language, as Zig can mix compile-time informations with runtime-only data to optimize the encoding and decoding code paths.

## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

The latest version of the zig compiler used for this project is 0.13.0.

This project is currently able to handle all scalar types for encoding, decoding, and generation through the plugin.

## Branches

There are 2 branches you can use for your development.

* `master` is the branch with current developments, working with the latest stable release of zig.
* `zig-master` is a branch that merges the developments in master, but works with the latest-ish master version of zig. 

## How to use

1. Add `protobuf` to your `build.zig.zon`.  
    ```zig
    .{
        .name = "my_project",
        .version = "0.0.1",
        .paths = .{""},
        .dependencies = .{
            .protobuf = .{
                .url = "https://github.com/Arwalk/zig-protobuf/archive/<some-commit-sha>.tar.gz",
                .hash = "12ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                // leave the hash as is, the build system will tell you which hash to put here based on your commit
            },
        },
    }
    ```
1. Use the `protobuf` module   
    ```zig
    pub fn build(b: *std.Build) !void {
        // first create a build for the dependency
        const protobuf_dep = b.dependency("protobuf", .{
            .target = target,
            .optimize = optimize,
        });

        // and lastly use the dependency as a module
        exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
    }
    ```


## Generating .zig files out of .proto definitions

You can do this programatically as a compilation step for your application. The following snippet shows how to create a `zig build gen-proto` command for your project.

```zig
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    // first create a build for the dependency
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });
    
    ...

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            "protocol/all.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);
}
```

If you're really bored, you can buy me a coffe here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
