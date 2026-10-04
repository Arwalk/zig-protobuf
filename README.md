# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository implements [protocol buffers](https://protobuf.dev/) for `proto2`, `proto3` and
[editions](https://protobuf.dev/editions/overview/) (up to edition 2026), including [extensions](#extensions).

This project is mature enough to be used in production. It passes the upstream
[conformance suite](conformance/) (protobuf v36.2) for the proto2, proto3 and editions test messages, in binary and JSON. The text format is not supported.

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

The in-development `edition = "UNSTABLE"` is rejected by default, as its features may change
in any protobuf release. To accept it, set `.experimental_editions = true` in the options of
`RunProtocStep`, which passes `--experimental_editions` to protoc and to the generator.

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

## Extensions

A message that declares extension ranges keeps its extensions in `_extensions`, a
`protobuf.ExtensionSet` of wire records. They are encoded again as they were decoded, without
any setup. The set only holds well-formed records: plain bytes cannot be assigned to it, and
`protobuf.ExtensionSet.fromBytes` validates the bytes it copies. Each extension is a
generated `protobuf.Extension` declaration, in the scope (file or message) that declares it:

```proto
message Extendable {
  extensions 100 to 199;
}

extend Extendable {
  optional int32 number = 100;
}
```

```zig
var msg: pb.Extendable = .{};
defer msg.deinit(allocator);

try pb.number.set(&msg, allocator, 7);
if (pb.number.has(msg)) {
    // Singular extensions are `?T`, repeated extensions are `std.ArrayList(T)`.
    var value = try pb.number.get(msg, allocator);
    defer pb.number.deinitValue(&value, allocator);
}
try pb.number.clear(&msg, allocator);
```

`get` decodes the extension when you call it. Singular extensions are `null` when not set;
their declared default value is `pb.number.default`.

### Registry

Some operations must know the extensions, as they need their names and types:

* Validation while decoding (for example, UTF-8 of strings).
* JSON, where an extension is written as `"[full.name]": value`.

Each generated file has an `extensions` declaration, which lists its extensions. Make a
registry from these lists, and give it to these operations:

```zig
const registry: protobuf.ExtensionRegistry = .init(pb.extensions ++ other_pb.extensions);

var msg = try protobuf.decodeWithOptions(pb.Extendable, &reader, allocator, .{ .extensions = &registry });
const json = try msg.jsonEncode(.{}, .{ .extensions = &registry }, allocator);
const parsed = try protobuf.json.decodeWithOptions(pb.Extendable, json, .{}, .{ .extensions = &registry }, allocator);
```

Without a registry, decoding does not validate extensions, and JSON does not contain them.

Messages with `option message_set_wire_format = true` encode their extensions in the MessageSet
format. The `StreamDecoder` skips extensions, like unknown fields.

The `extensions` declaration shares the top-level scope of the file. Thus, a file must not have
a message, enum, extension or service with the name `extensions`.

## Options

The generator decodes the [options](https://protobuf.dev/programming-guides/proto3/#options) of
each declaration, standard and custom, into comptime constants. Each constant is an anonymous
struct of the options that are set. Custom options are keyed by the full name of their extension.

| Declaration | Generated declaration |
| --- | --- |
| file | `_file_options.@"file.proto"` (files of a package share its output) |
| message, enum, service | `_options` |
| field, oneof | `_field_options.<field>`, `_oneof_options.<oneof>` of the message |
| enum value | `_value_options.<VALUE>` of the enum |
| method | `_method_options.<Method>` of the service |
| extension | `options` of the extension |
| extension range | `_extensions_info.range_options[i]` of the message |

Only the declarations that have options are listed.

```proto
extend google.protobuf.EnumValueOptions {
  string string_name = 123456789;
}

enum Data {
  DATA_UNSPECIFIED = 0;
  DATA_SEARCH = 1 [deprecated = true];
  DATA_DISPLAY = 2 [(string_name) = "display_value"];
}
```

```zig
pub const Data = enum(i32) {
    DATA_UNSPECIFIED = 0,
    DATA_SEARCH = 1,
    DATA_DISPLAY = 2,
    _,

    pub const _value_options = .{
        .DATA_SEARCH = .{ .@"#raw" = "\x08\x01", .deprecated = true },
        .DATA_DISPLAY = .{ .@"#raw" = "\xaa\xd1\xf9\xd6\x03\rdisplay_value", .@"pkg.string_name" = "display_value" },
    };
};

const name = pb.Data._value_options.DATA_DISPLAY.@"pkg.string_name"; // "display_value"
```

Values are Zig literals: strings for `string` and `bytes`, enum literals for enums, tuples for
repeated values, and anonymous structs for messages (MessageSet items become extensions). An
option whose extension is not part of the protoc request cannot be decoded; its value is kept
as raw bytes, keyed by its field number.

The option tests of protobuf (`CustomOptions` and `RetentionTest`) run on its test protos, in
`tests/tests_upstream_options.zig`.

Each set of options also has `@"#raw"`: the encoded `google.protobuf.*Options` message, for the
usual decoding APIs. Custom options decode with `getFromBytes`, and standard options with the
options message, for example `google_protobuf.FieldOptions.decode`:

```zig
var name = try pb.string_name.getFromBytes(pb.Data._value_options.DATA_DISPLAY.@"#raw", allocator);
defer pb.string_name.deinitValue(&name, allocator); // name.? == "display_value"
```

protoc checks the [option targets](https://protobuf.dev/programming-guides/proto3/#option-targets)
and removes the [source-retention](https://protobuf.dev/programming-guides/proto3/#option-retention)
options. It removes them only in the files to generate, so the generator does not keep the
options of the files that are only imported.

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
