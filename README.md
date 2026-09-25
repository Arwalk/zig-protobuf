# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository implements [protocol buffers](https://protobuf.dev/) for `proto2`, `proto3` and
[editions](https://protobuf.dev/editions/overview/) (up to edition 2026). Extensions are not supported.

This project is mature enough to be used in production. It passes the upstream
[conformance suite](conformance/) (protobuf v36.2) for the proto2, proto3 and editions test messages, in binary and JSON.

json encoding/decoding is considered a beta feature.

## Editions

Editions replace the `syntax` keyword with fine grained *features*, which can be set for a
whole file or for individual fields and enums. `proto2` and `proto3` are handled as the
legacy editions they correspond to, so the same rules apply to all three. The generator
resolves the features of every element and maps them to Zig as follows:

| Feature | Zig representation |
| --- | --- |
| `field_presence = EXPLICIT` | optional field `?T = null`. The `[default = ...]` value is in `defaults`. Refer to [Default values](#default-values) |
| `field_presence = IMPLICIT` | plain field `T` holding the zero value, which is not serialized |
| `field_presence = LEGACY_REQUIRED` | plain field `T` without default, always serialized |
| `enum_type = OPEN` | non-exhaustive enum (`_`), unknown values are kept |
| `enum_type = CLOSED` | exhaustive enum, unknown values are stored as unknown fields |
| `repeated_field_encoding` | `.packed_repeated` or `.repeated` field descriptor |
| `message_encoding = DELIMITED` | `fdf(n, .submessage, .{ .message_encoding = .delimited })`, encoded as a group |
| `utf8_validation = VERIFY` | `fdf(n, .{ .scalar = .string }, .{ .utf8_validation = .verify })`, invalid strings fail to decode |

```proto
edition = "2023";

message Example {
  int32 explicit = 1;                                          // ?i32 = null
  int32 implicit = 2 [features.field_presence = IMPLICIT];     // i32 = 0
  Nested nested = 3 [features.message_encoding = DELIMITED];   // encoded as a group
}
```

## Default values

> **CAUTION:** This behavior is different from the behavior of previous versions.
> Previous versions set optional fields to their `[default = ...]` value.
> Examine your code before you update.

### Presence and value

A field with explicit presence has two properties:

1. Its presence. The field is set or not set.
2. Its value. A set field has the value that it holds. A field that is not set has its default value.

In Zig, an optional field (`?T`) holds the two properties. The value `null` shows that the field is not set.

### Encoding

The encoder examines only the presence of a field. It does not compare the value with the default value.

* The encoder does not write a field that is not set.
* The encoder writes a field that is set. This is also correct when the value is equal to the default value.

Example, for `optional int32 x = 1 [default = 5];`:

| Sender | Wire | Receiver |
| --- | --- | --- |
| Does not set `x` | no data | `x == null`, the value is 5 |
| Sets `x` to 5 | `x = 5` | `x == 5` |
| Sets `x` to 7 | `x = 7` | `x == 7` |

The receiver can find the difference between the first two rows. The value is the same, but the presence is different.

### How to read a value

The generator puts the declared default values in the `defaults` declaration of the message:

```zig
pub const Example = struct {
    x: ?i32 = null,

    /// Default values of fields that are `null` when not set.
    pub const defaults = struct {
        pub const x: i32 = 5;
    };
    // ...
};
```

To get the value of a field, use the default value when the field is not set:

```zig
const x = msg.x orelse Example.defaults.x;
```

To set a field to its default value, set it explicitly. The encoder then writes the field:

```zig
msg.x = Example.defaults.x;
```

The library does not use `defaults` during encoding or decoding. It is only for your code.

### Changes from previous versions

Previous versions set an optional field to its default value, for example `x: ?i32 = 5`. This caused these problems:

* A new message (`.{}`) had all fields with a default value set.
* A decoded message had all fields with a default value set, also when the input did not contain them.
* The encoder wrote all these fields, because they were set.

To update your code, do these steps:

1. Find the code that reads an optional field with a default value.
2. Replace `msg.x.?` with `msg.x orelse Example.defaults.x`.
3. Replace comparisons such as `msg.x == 5` with `(msg.x orelse Example.defaults.x) == 5`.

### Other fields

* A field with implicit presence (proto3 `int32 x = 1;`) has no presence. Its default value is always zero. The encoder does not write the zero value.
* A required field (proto2 `required`) is a plain field (`T`). The encoder always writes it, also when its value is zero.
* The default value of a closed enum is its first value. This value is not always zero.

### Names

`defaults` is a declaration of the message. Thus, a message must not have a field, oneof, message or enum with the name `defaults`. If it has one, the generator stops with an error.

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
        // Optional LazyPath to `protoc`. If null, zig-protobuf will download Google's release of
        // the compiler.
        // .protoc = b.path("protoc"),
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
length-delimited fields points back into the decoder itself. Messages with delimited
(group-encoded) fields are not supported by the `StreamDecoder`.

-------

The zig-protobuf logo is licensed under the Attribution 4.0 International (CC BY 4.0).

The logo is inspired by the [official mascots](https://github.com/ziglang/logo?tab=readme-ov-file#official-mascots) of the Zig programming language, themselves licensed under the Attribution 4.0 International (CC BY 4.0)

Original art by vivisector.

-------

If you're really bored, you can buy me a coffee here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
