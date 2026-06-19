# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

This project is mature enough to be used in production.

json encoding/decoding is considered a beta feature.

## Branches

There are 2 branches you can use for your development.

* `master` is the branch with current developments, working with the latest stable release of zig.
* `zig-master` is a branch that merges the developments in master, but works with the latest-ish master version of zig. 

## How to use

1. Add `protobuf` to your `build.zig.zon`.  
    ```sh
    zig fetch --save "git+https://github.com/Arwalk/zig-protobuf#master"
    ```
1. Use the `protobuf` module. In your `build.zig`'s build function, add the dependency as module before
`b.installArtifact(exe)`.
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

    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        // Optional custom generator, otherwise it will use the built-in generator + google's protoc
        // .generator = protobuf_dep.artifact("protoc-gen-zig"),
        .source_files = &.{
            b.path("protocol/all.proto"),
        },
        .include_directories = &.{},
        // Preserve unknown fields during binary decode/encode round trips.
        // Defaults to false.
        .preserve_unknown_fields = false,
    });

    gen_proto.dependOn(&protoc_step.step);
}
```

## Service Code Generation

zig-protobuf generates code for Protocol Buffer `service` definitions using the delegate pattern. This provides a flexible, type-safe interface for implementing gRPC-compatible services with custom server contexts.

**Note**: This generates service interfaces only. It does not include a gRPC transport layer - users must implement their own server logic and transport.

For detailed documentation on service code generation, including examples and usage patterns, see [docs/services.md](docs/services.md).

## Streaming decode

Besides `MyMessage.decode`, which materializes a whole message (allocating storage for
every dynamic field), every generated message also exposes a `StreamDecoder`: a
zero-allocation **pull parser** that walks a `std.Io.Reader` one wire field at a time.
This is useful for incremental / low-memory decoding — large or deeply nested messages,
embedded systems, or multiplexed IO — where you don't want to buffer a whole message in
contiguous memory. It implies some caveats and limitations though, see `src/stream.zig`

Call `next()` to get the next field as an `Event`. Scalars come back by value; the leaf
cases of a `oneof` are flattened into their own variants. Length-delimited fields
(submessages, `string`, `bytes`) are surfaced as a `*std.Io.Reader` bound to that
field's bytes — you can recurse into it with another `StreamDecoder`, copy the bytes out,
or simply ignore it (the decoder drains it for you on the next call). `next()` returns
`null` at the end of the stream.

```zig
var sd = MyMessage.StreamDecoder.init(&reader);
while (try sd.next()) |item| switch (item) {
    .some_scalar => |v| { ... },                  // value, by value
    .some_string => |limited| {                   // limited: *std.Io.Reader
        var buf: [64]u8 = undefined;
        const n = try limited.readSliceShort(&buf);
        ...
    },
    .some_submessage => |limited| {               // recurse without allocating
        var inner = SubMessage.StreamDecoder.init(limited);
        while (try inner.next()) |x| switch (x) { ... };
    },
    // repeated fields (packed or not) emit one event per element
    .some_repeated => |v| { ... },
};
```

Note: the decoder must not be copied after `init` — the `*std.Io.Reader` it hands out for
length-delimited fields points back into the decoder itself.

-------

The zig-protobuf logo is licensed under the Attribution 4.0 International (CC BY 4.0).

The logo is inspired by the [official mascots](https://github.com/ziglang/logo?tab=readme-ov-file#official-mascots) of the Zig programming language, themselves licensed under the Attribution 4.0 International (CC BY 4.0)

Original art by vivisector.

-------

If you're really bored, you can buy me a coffee here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
