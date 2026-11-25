# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository implements [protocol buffers](https://protobuf.dev/) for `proto2`, `proto3` and
[editions](https://protobuf.dev/editions/overview/) (up to edition 2026), including
[extensions](doc/legacy.md#extensions).

This project is mature enough to be used in production. It passes the upstream
[conformance suite](conformance/) (protobuf v36.2) for the proto2, proto3 and editions test messages, in binary and JSON. The text format is not supported.

The sections below are enough to start. [doc/legacy.md](doc/legacy.md) has the rest, such as
default values, extensions, options, streaming decode and the update from version 5.

The code below comes from [doc/example](doc/example/), a small project that you can build and run
with `zig build run`.

## How to use

### Add the library to your project

Add `protobuf` to your `build.zig.zon`:

```sh
zig fetch --save "git+https://github.com/Arwalk/zig-protobuf#master"
```

Then use the `protobuf` module. In your `build.zig`'s build function, add the dependency as module
before `b.installArtifact(exe)`:

<!-- snippet: doc/example/build.zig#dependency -->
```zig
// first create a build for the dependency
const protobuf_dep = b.dependency("protobuf", .{
    .target = target,
    .optimize = optimize,
});

// and lastly use the dependency as a module
exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
```

### Decode and encode a message

Import the code generated from your `.proto` files (refer to
[the next section](#generating-zig-files-out-of-proto-definitions)):

<!-- snippet: doc/example/src/main.zig#imports -->
```zig
const std = @import("std");
const example = @import("proto/example.pb.zig");
```

Decode a message from bytes, and read its fields:

<!-- snippet: doc/example/src/main.zig#decode -->
```zig
// `input` is a `[]const u8`. Any other `std.Io.Reader` works too.
var reader: std.Io.Reader = .fixed(input);
var project: example.Project = try .decode(&reader, allocator);
defer project.deinit(allocator);

for (project.data.items) |entry| {
    try stdout.print("{s}: {s}\n", .{ entry.key, entry.value });
}
```

Encode it back:

<!-- snippet: doc/example/src/main.zig#encode -->
```zig
// `Allocating` is a `std.Io.Writer` to memory. Any other `std.Io.Writer` works too.
var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();
try project.encode(&output.writer, allocator);

try stdout.print("{x}\n", .{output.written()});
```

In the example, this prints:

<!-- snippet: doc/example/expected_output.txt -->
```text
project_author: Arwalk
project_name: zig-protobuf
project_language: Zig
0a180a0e70726f6a6563745f617574686f721206417277616c6b0a1c0a0c70726f6a6563745f6e616d65120c7a69672d70726f746f6275660a170a1070726f6a6563745f6c616e677561676512035a6967
```

## Generating .zig files out of .proto definitions

You can do this programmatically as a compilation step for your application. Take this definition,
in `proto/project.proto`:

<!-- snippet: doc/example/proto/project.proto -->
```proto
syntax = "proto3";

package example;

message Project {
  map<string, string> data = 1;
}
```

The following snippets of `build.zig` create a `zig build gen-proto` command for your project:

<!-- snippet: doc/example/build.zig#gen-proto-import -->
```zig
const protobuf = @import("protobuf");
```

<!-- snippet: doc/example/build.zig#gen-proto -->
```zig
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
```

The generated file has the name of the package, here `src/proto/example.pb.zig`. Each message is a
struct, with functions such as `decode`, `encode` and `deinit`. A map is a list of entries:

<!-- snippet: doc/example/src/proto/example.pb.zig -->
```zig
pub const Project = struct {
    data: std.ArrayList(Project.DataEntry) = .empty,

    pub const _desc_table = .{
        .data = fd(1, .{ .repeated = .submessage }),
    };

    pub const DataEntry = struct {
        key: []const u8 = &.{},
        value: []const u8 = &.{},

        pub const _desc_table = .{
            .key = fdf(1, .{ .scalar = .string }, .{ .utf8_validation = .verify }),
            .value = fdf(2, .{ .scalar = .string }, .{ .utf8_validation = .verify }),
        };
```

### Building protoc from source

If you do not want a binary downloaded into your build, `protocFromSource` builds `protoc` from its
sources, with nothing but the Zig toolchain. Use it in the options of `RunProtocStep`:

<!-- snippet: tests/source_protoc/build.zig#protoc-from-source -->
```zig
.protoc = protobuf.protocFromSource(protobuf_dep.builder),
```

This is the same version of `protoc` as the download, and it finds the well-known types such as
`google/protobuf/timestamp.proto` on its own. It is always built for the machine that runs the
build, whatever your `target` is.

The first build costs a download of about 12 MB of sources, close to 3 minutes of compilation on 16
cores, and about 1 GB in `.zig-cache`. Later builds reuse the cache.

The sources are only fetched by a call to `protocFromSource`, whatever step you run, and the Google
release is then not downloaded. To make it a choice in your project, only call it when needed, for
example behind a build option.

## Service Code Generation

zig-protobuf generates code for Protocol Buffer `service` definitions as a VTable: a struct of
function pointers, for the user data type and the error set that you give. This provides a flexible,
type-safe interface for implementing gRPC-compatible services with custom server contexts.

**Note**: This generates service interfaces only. It does not include a gRPC transport layer - users must implement their own server logic and transport.

For detailed documentation on service code generation, including examples and usage patterns, see [docs/services.md](docs/services.md).

-------

The zig-protobuf logo is licensed under the Attribution 4.0 International (CC BY 4.0).

The logo is inspired by the [official mascots](https://github.com/ziglang/logo?tab=readme-ov-file#official-mascots) of the Zig programming language, themselves licensed under the Attribution 4.0 International (CC BY 4.0)

Original art by vivisector.

-------

If you're really bored, you can buy me a coffee here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
