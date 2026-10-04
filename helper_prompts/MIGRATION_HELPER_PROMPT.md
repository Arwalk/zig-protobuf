# Migration helper prompt: zig-protobuf 5.x to 6.0.0

This file is a prompt for a coding agent. It makes the agent analyse **your** project and report
what the upgrade of zig-protobuf from 5.x to 6.0.0 changes for you: which messages are at risk,
which code needs a different handling, and which questions only you can answer.

How to use it:

1. Open a coding agent at the root of the project that depends on zig-protobuf.
2. Give it everything below the line as the prompt (or tell it to read this file and follow it).
3. Read the report. The agent does not change your project.

It works before the upgrade (recommended) and after it, with old or regenerated `*.pb.zig` files.

---

You are going to analyse this project for the upgrade of the zig-protobuf library from 5.x to
6.0.0. Version 6.0.0 adds proto2, editions and extensions support. To do this correctly, it
changes the code that the generator emits and some behavior of the encoder, the decoder and JSON.
Most changes do not produce a compile error: the code compiles and then behaves differently. Your
analysis is how the developer finds these places before they become bugs.

## Rules for this task

This is an analysis only. The developer applies the changes later, with the report as a guide.

- Do not create, edit, move or delete any file of the project. Do not write the report to a file;
  give it as your answer. If the developer asks for a file after they read it, that is their
  decision.
- Do not run `zig build`, `zig fetch`, `protoc` or the project's scripts. A build of a project
  that uses `RunProtocStep` regenerates the `*.pb.zig` files in the source tree, and so changes
  the project. Read and search only (file reads, `grep`, `ls`, and `git log` / `git grep` when
  the project is a git repository). You can inspect a binary data file (a test fixture, for
  example) with a read-only command, if the command writes nothing in the project.
- Do not change the dependency version, and do not commit.
- Each finding must point to `path:line` in this project and quote the line. If you did not see
  the line, it is not a finding. When you are not sure, put the item in the "Questions" section of
  the report and say what you could not establish.
- Suggested replacements are part of the report, as text. Do not apply them.

## Step 1: Inventory

Collect these facts first. The report starts with them.

1. **Dependency.** In `build.zig.zon`, find the zig-protobuf dependency (URL, ref or hash). If you
   can read the package itself (`zig-pkg/`, `~/.cache/zig/p/<hash>/`, a vendored directory), read
   its `build.zig.zon` version and check for `src/extension.zig` (only in 6.0.0) and
   `src/stream.zig` (not in the `v5.0.0` tag, added on `master` after it). If there is no
   dependency entry (the library is vendored or in the same tree), say so and continue with the
   generated files as the evidence.
2. **Starting point.** Decide which of these the project uses now. It decides which entries of the
   catalogue apply:
   - **Tag 5.0.0**: generated messages have no `pub const StreamDecoder` declaration.
   - **Post-5.0.0 `master`**: generated messages have `pub const StreamDecoder =
     protobuf.StreamDecoder(@This());` but no file has `protobuf.ExtensionSet`, `fdf(` or a
     `pub const defaults = struct`.
   - **Already 6.0.0 bindings**: files contain `const fdf = protobuf.fdf;`, `protobuf.ExtensionSet`
     or `pub const defaults = struct`. The bindings are regenerated; analyse the code that uses
     them.
3. **Build integration.** In `build.zig`, find `RunProtocStep.create` / `createWithGenerator` and
   record `source_files`, `include_directories`, `destination_directory`, and the options
   `protoc`, `generator`, `preserve_unknown_fields`. Find any script or CI step that calls
   `protoc --zig_out` directly.
4. **Proto files.** List each `.proto` input and its transitive imports. For each: `syntax`
   (`proto2`, `proto3`) or `edition`, and package. A file without a `syntax` line is proto2.
5. **Generated files.** List the `*.pb.zig` files and which proto package each comes from.
6. **Hand-written descriptors.** Find structs with a `_desc_table` declaration outside `*.pb.zig`
   files, and calls to `protobuf.fd(`.
7. **Usage.** Find where the project uses the library: `.decode(`, `.encode(`, `.jsonDecode(`,
   `.jsonEncode(`, `.dupe(`, `protobuf.json.`, `StreamDecoder`, `_unknown_fields`, `.init(`.

## Step 2: Check the catalogue

Each entry gives the change, how to find the messages and code that it affects, and what to
suggest. Entries marked **[tag only]** are already present on post-5.0.0 `master`: skip them if
the starting point is `master`. Check each other entry. For each entry, say in the report if it
applies, with the evidence, or that you checked it and found nothing.

Severity classes, used in the report:

- **GEN**: the generator stops with an error; no bindings until the proto is changed.
- **COMPILE**: the project's code stops compiling. Easy to find, and the compiler confirms the fix.
- **SILENT**: the code compiles and behaves differently at runtime. Highest priority.
- **OUTPUT**: the bytes or JSON that the project produces change. Matters when another program, a
  stored file, a cache key, a signature or a golden test depends on them.
- **INFO**: new and additive. No action needed.

### A. Generated code

**A1. Fields with a declared default are `null` until set** (SILENT, OUTPUT)

Trigger: a proto2 field `optional T x = N [default = V];` (in editions: a field with explicit
presence and a `default`). Fields of a oneof with a default are in the same case.

```zig
// 5.x                               // 6.0.0
extent: ?u32 = 4096,                 extent: ?u32 = null,
                                     pub const defaults = struct {
                                         pub const extent: u32 = 4096;
                                     };
```

Effects:
- A new message (`.{}`) and a decoded message no longer have these fields set. `msg.x.?` panics in
  safe builds and is undefined behavior in `ReleaseFast`. `msg.x == V` is false.
- The encoder and JSON no longer write these fields when the code did not set them. In 5.x each
  message carried all its defaulted fields on the wire.
- The decoder does not apply defaults. The library never reads `defaults`; it is for your code.

Find: in the `.proto` files, `default =`. In old bindings, an optional field with a non-null
initializer (`: ?T = <not null>`). Then each read of these fields in the project: `.x.?`,
`.x == `, `.x != `, `if (msg.x) |v|`, `orelse`, `switch (msg.x.?)`, and code that formats or
copies the message.

Suggest: `msg.x orelse Msg.defaults.x`. To send the default explicitly, `msg.x = Msg.defaults.x`.

The value in `defaults` is the same literal that 5.x used as the initializer of the field.

Not affected: proto2 `optional` fields without a default and proto3 `optional` fields (they were
already `?T = null`), and `required` fields with a default (they stay a plain `x: T = V`).

**A2. Enums of proto2 files are closed: exhaustive Zig enums** (COMPILE, SILENT)

Trigger: each enum declared in a proto2 file (in editions: `features.enum_type = CLOSED`). Enums
of proto3 files do not change (they keep the `_` member).

```zig
// 5.x                                         // 6.0.0
pub const Kind = enum(i32) { A = 1, B = 2, _ };   pub const Kind = enum(i32) { A = 1, B = 2 };
```

Effects:
- COMPILE: a `switch` on such an enum with a `_ =>` prong, or with an `else =>` prong when all
  values are listed, no longer compiles.
- SILENT: `@enumFromInt(n)` with a number that is not a declared value is illegal behavior (it was
  a valid unnamed value).
- SILENT: when the decoder reads a number that the enum does not declare, it does not store it
  (see B1).

Find: enums in proto2 files; then `switch` statements on values of these types, `@enumFromInt`
with these types, `std.meta.intToEnum`, and `@intFromEnum` on decoded values that the code
compares to numbers outside the declared set.

**A3. Map entries of proto2 files are not optional** (COMPILE, SILENT, OUTPUT)

Trigger: `map<K, V>` in a proto2 file. proto3 maps do not change.

```zig
// 5.x                        // 6.0.0
key: ?[]const u8 = null,      key: []const u8 = &.{},
value: ?i32 = null,           value: i32 = 0,
```

Message values stay `?Msg`. Effects: `entry.key.?`, `entry.value.?` and `if (entry.value) |v|` no
longer compile. A key or value equal to zero is no longer written, and a missing one decodes as
zero, not `null`.

Find: `map<` in proto2 files; the generated `...Entry` structs; code that reads `.key` or `.value`
of these entries.

**A4. Messages with extension ranges have an `_extensions` field** (SILENT, INFO)

Trigger: a message with `extensions N to M;`.

```zig
_extensions: protobuf.ExtensionSet = .empty,
pub const _extensions_info = .{ .ranges = .{ .{ 100, 200 } }, .message_set = false };
```

Effects:
- Code that iterates the fields of the struct (`std.meta.fields`, `@typeInfo(T).@"struct".fields`,
  generic equality, hashing, printing or serialization helpers) sees a field that is not a proto
  field. It has no entry in `_desc_table`, so `@field(T._desc_table, field.name)` does not compile
  for it (the same as for `_unknown_fields`). It holds a slice: `std.meta.eql` compares it by
  pointer, and deep helpers such as `std.testing.expectEqualDeep` compare its content.
- Data in these ranges is now kept and encoded again (see B6).
- `_extensions` does not accept plain bytes. Use `protobuf.ExtensionSet.fromBytes`, or the
  generated extension declarations (`pb.my_ext.set(&msg, allocator, value)`).

Find: `extensions ` statements in messages; reflection or generic helpers applied to these
message types.

**A5. Names that the generator now rejects** (GEN)

- A message that gets a `defaults` declaration (A1) must not have a field, oneof, nested message,
  nested enum or extension named `defaults`.
- A package that declares extensions (`extend`) must not have a top-level message, enum, extension
  or service named `extensions`.
- An `edition` outside proto2 to 2026 is rejected. `edition = "UNSTABLE"` needs
  `.experimental_editions = true` in the `RunProtocStep` options.
- **[tag only]** Each message has a `StreamDecoder` declaration. A nested message or enum named
  `StreamDecoder` conflicts with it.

Find: these names in the `.proto` files.

**A6. Recursive message fields are pointers** [tag only] (COMPILE)

Trigger: a singular message field with the type of a message that contains it (directly or as an
ancestor), for example the value of `map<K, Self>`. The field is `?*T`, it was `?T`.

Find: self-referential messages in the `.proto` files; in old bindings compare `?T` and `?*T` on
these fields; code that builds or reads these fields.

**A7. Well-known types come from `protobuf.wkt`** [tag only] (COMPILE, OUTPUT)

Trigger: use of `google.protobuf` `Any`, `Duration`, `Empty`, `FieldMask`, `Struct`, `Value`,
`ListValue`, `Timestamp`, `NullValue` or the wrappers (`Int32Value`, `StringValue`, ...). The
generated file has `pub const Timestamp = protobuf.wkt.Timestamp;` in place of a struct.

Effects: `Value._kind_case` no longer exists and the order of the `kind_union` tags changed.
`Struct.FieldsEntry` has no `encode`/`decode`. Field names and types are the same. The JSON form
changes (see C5).

Find: imports of `google/protobuf` bindings; `_kind_case`; `FieldsEntry`.

**A8. Enum aliases** [tag only] (COMPILE)

Trigger: an enum with `option allow_alias = true;`. Names with a duplicate value are not members
of the Zig enum; they are in `pub const _json_aliases`.

Find: `allow_alias` in the `.proto` files; uses of the alias names.

**A9. New declarations** (INFO)

`defaults`, `_extensions_info`, `_options`, `_field_options`, `_oneof_options`, `_value_options`,
`_method_options`, `_file_options`, and one `extensions` tuple for each package with `extend`
blocks. Proto2 `group` fields and `extend` blocks now generate code (a group in a proto made the
5.x generator crash; `extend` blocks produced nothing). The option tables are only emitted for
files given to protoc, not for files that are only imported.

Report only if the project has code that enumerates the declarations of generated types
(`@typeInfo(T).@"struct".decls`, `std.meta.declarations`).

**A10. Reflection on descriptors** (INFO)

Trigger: project code that reads `_desc_table` of generated types. `protobuf.FieldType` has the
same variants, so a `switch` on `.ftype` still compiles. `protobuf.FieldDescriptor` has a new
`features` field. Code that calls `field.ftype.toWire()` should call `field.toWire()`, which
knows about groups.

### B. Binary encoding and decoding

**B1. Unknown values of closed enums are not stored in the field** (SILENT)

Trigger: a message decoded by the project that has a field of a proto2 enum (A2), when the sender
can use a newer schema with more values.

Effects: a singular field keeps its previous value (`null` after a fresh decode); a repeated field
drops the element; in a oneof, the oneof is not set. The value goes to `_unknown_fields` when the
bindings are generated with `preserve_unknown_fields`, else it is lost. In 5.x the field held the
number.

Find: decoded messages with proto2 enum fields. Code that handled unknown numbers (`_ =>`,
`@intFromEnum(x) == <number>`) shows that the project expects them.

Suggest: handle `null` as "unknown or absent"; turn on `preserve_unknown_fields` if the value must
survive a decode and encode cycle.

**B2. Strings of proto3 and editions files are checked as UTF-8** (SILENT, depends on data)

Trigger: each `string` field (singular, repeated, map key or value, oneof member) in a proto3 or
editions file, in a message that the project decodes. Decoding fails with `error.InvalidInput`
when the bytes are not valid UTF-8. proto2 strings are not checked. 5.x accepted any bytes.

Find: `string` fields in proto3 files, in messages that reach `.decode(`.

You cannot decide this from the code. Report the exposed messages and where their input comes
from, and ask the developer if a sender can put binary data in a `string` field. If yes, the
field must become `bytes`.

**B3. Required fields are always written** (OUTPUT)

Trigger: proto2 `required` fields (editions: `LEGACY_REQUIRED`). A required field with the value
zero, `false`, `""` or the enum value 0 is now on the wire. In 5.x it was skipped. A missing
required field is still not a decode error.

Find: `required` in proto2 files, in messages that the project encodes.

**B4. The default of an enum is its first declared value** (SILENT, OUTPUT)

Trigger: an enum with a first value that is not 0, used in a field that is not optional (a
required field, or a hand-written descriptor). The initial value of the field and the value that
the encoder skips are the first value. In 5.x both were 0.

Find: enums with a non-zero first value; non-optional fields of these types.

**B5. Fields of a second oneof are decoded** (SILENT, a fix)

Trigger: a message with two or more `oneof` blocks. In 5.x the decoder could drop the fields of
each oneof after the first. Code that worked around this (a second decode, a manual parse, a field
moved out of the oneof) can be removed; code that never saw these fields set now sees them.

Find: messages with more than one `oneof`; code that reads the later ones.

**B6. Data in extension ranges is kept in `_extensions`** (SILENT, OUTPUT)

Trigger: messages of A4 that the project decodes and encodes again. In 5.x these fields were
dropped, or kept in `_unknown_fields` with `preserve_unknown_fields`. Now they are always kept,
and written after the known fields and before the unknown fields.

Find: messages of A4 on a decode and encode path; code that reads `_unknown_fields` of these
messages to find extension data.

**B7. Unknown fields** (SILENT; only with `preserve_unknown_fields`)

- Unknown groups are kept (5.x lost them).
- Unknown values of closed enums are stored there (B1), so they are written at the end of the
  message, not at their first position.
- A decode into a message that already has unknown fields appends to them (5.x replaced them).

Find: `preserve_unknown_fields` in `build.zig`; code that reads or compares `_unknown_fields`.

**B8. Input validation** (SILENT, depends on data)

Now rejected with `error.InvalidInput`: a tag longer than 5 bytes or above 32 bits, a negative
length of a repeated or packed field (5.x panicked), a group without its end tag.
**[tag only]** Field number 0 is rejected. An `int32`/`uint32` varint that is too long or out of
range is truncated, not rejected. A `bool` accepts each varint (non-zero is `true`). `decode`
frees the partial result when it fails.

Report only if the project decodes input that it does not control, or has tests that expect
specific decode errors.

**B9. Repeated enums of proto3 files are packed** [tag only] (OUTPUT)

Trigger: `repeated SomeEnum` in a proto3 file. The encoder writes the packed form. The decoder
accepts both forms.

### C. JSON

Report this section only if the project uses `jsonEncode`, `jsonDecode` or `protobuf.json`.

**C1. Fields with a declared default are not written when not set** (OUTPUT). Same cause as A1.

**C2. Required fields are always written** (OUTPUT). Also when they hold zero.

**C3. Numbers for closed enums** (SILENT). A number that the enum does not declare fails with
`error.InvalidEnumTag`. With `ignore_unknown_fields`, an optional enum field becomes `null`.
Find: `jsonDecode` of messages with proto2 enums.

**C4. Fields with implicit presence at their zero value are not written** [tag only] (OUTPUT).
`0`, `false`, `""`, empty bytes, the zero enum value and empty lists are omitted.

**C5. Well-known types have their protobuf JSON form** [tag only] (OUTPUT, SILENT).
`Timestamp` is an RFC 3339 string, `Duration` is `"1.5s"`, `FieldMask` is a comma-separated
string, wrappers are bare values, `Value`/`Struct`/`ListValue` are plain JSON (`1`, not
`{"kind":{"numberValue":1}}`). A `Value` nested more than 100 levels is rejected. `Any` with a
`type_url` fails to encode and to parse unless `protobuf.wkt.any_json_resolver` is set.
Find: messages with these types on a JSON path.

**C6. 64-bit integers are strings** [tag only] (OUTPUT). `int64`, `uint64`, `sint64`, `fixed64`,
`sfixed64` are written as `"123"`. The parser accepts both forms.

**C7. Maps are JSON objects** [tag only] (OUTPUT, SILENT). `{"k": v}` with the keys as strings.
5.x wrote an array of `{"key", "value"}` objects, and that form no longer parses.
Find: `map<` fields on a JSON path; stored JSON in the old form.

**C8. JSON names** [tag only] (OUTPUT, SILENT). The first character of a field name keeps its
case: the field `APIVersion` is `"APIVersion"`, it was `"aPIVersion"`. The old name is rejected
as an unknown field. Find: proto fields with a name that starts with an uppercase letter or `_`.

**C9. Parser** [tag only] (SILENT). `null` means "default" for scalar, enum and repeated fields.
Enums accept numbers, names in any case, and aliases. Bytes accept URL-safe and unpadded base64.
A number that overflows a float is rejected. Two members of the same oneof give
`error.DuplicateField`.

**C10. Extensions** (INFO). They are written as `"[full.name]": value`, and only when
`json.Options.extensions` has a registry. Parsing them needs `protobuf.json.decodeWithOptions`.

### D. Build

**D1. protoc 36.2** (was 32.1). Matters when the project gives its own `.protoc`, or runs protoc
outside `RunProtocStep`: a protoc older than the editions in the `.proto` files cannot parse them.

**D2. A protoc failure fails the build step.** A proto that produced warnings or errors that 5.x
did not stop on now stops the build.

**D3. Plugin parameters** [tag only]. `protoc-gen-zig` rejects parameters that it does not know.
It accepts `preserve_unknown_fields` and `experimental_editions`. Find: `--zig_out=<params>:` in
scripts.

**D4. New options** (INFO). `RunProtocStep` options `generator`, `protoc`,
`preserve_unknown_fields` **[tag only]** and `experimental_editions`. The existing options and
the `create` signature are the same. The minimum Zig version is 0.16.0, as before.

### E. Streaming decoder

Only when the project uses `StreamDecoder` (starting point `master`).

- COMPILE: `StreamDecoder` of a message with a group (delimited) field is a compile error.
- SILENT: an unknown value of a closed enum is skipped; it was `error.InvalidInput`.
- Extensions are skipped.

### F. Hand-written descriptors

Only when step 1.6 found some. `protobuf.fd` and existing `_desc_table` literals still compile.

- SILENT: B4 applies to each hand-written enum, open or closed.
- SILENT: a hand-written exhaustive enum no longer fails the decode on an unknown number (B1).
- SILENT: B5 applies to hand-written messages with two oneofs.
- A10 applies.
- INFO: `protobuf.fdf(number, type, .{ ... })` sets `legacy_required`, `message_encoding =
  .delimited` and `utf8_validation = .verify`. Extensions need both `_extensions:
  protobuf.ExtensionSet = .empty` and `_extensions_info`.

### What did not change

Do not report these: the signatures of the generated `encode`, `decode`, `deinit`, `dupe`,
`jsonEncode`, `jsonDecode` and `jsonParse`; the names and paths of generated files; packed and
unpacked encoding of repeated scalars; service generation; proto3 `optional` fields; proto2
`optional` fields without a default; `json.Options.emit_oneof_field_name` (default `true`).

## Step 3: Trace the usage

For each message or enum that an entry of the catalogue selects, find where the project uses it.
The same message is a different risk when the project only builds it than when it decodes it from
the network. Record for each one:

- built in code (struct literal, `.init`, field assignment);
- decoded (`.decode(`, `protobuf.decode`, `StreamDecoder`), and where the bytes come from;
- encoded, and where the bytes go (network peer, file, database, hash, signature, golden test);
- JSON encoded or decoded;
- read: each access to an affected field, each `switch` on an affected enum;
- handled by generic code (reflection, equality, copy, logging).

Follow type aliases and re-exports (`const Foo = pb.Foo;`), and functions that take the message
as `anytype`. If a message is never used by the project, say so; it then has no code to migrate.

## Step 4: The report

Give the report in this structure, in Markdown. Put the facts first; keep the explanations short,
the catalogue above has them. Use the entry identifiers (A1, B2, ...) so that the developer can
come back to this file.

1. **Summary.** Three to six lines: starting point found (and the evidence), number of proto files
   by syntax, number of messages at risk, number of code sites for each severity class, and the
   one or two things to handle first.
2. **Inventory.** The facts of step 1, as a short list.
3. **Messages and enums at risk.** One table, one row for each message or enum:

   | Message or enum | Proto file | Entries | Highest severity | How the project uses it | Sites |
   |---|---|---|---|---|---|

   Sort by severity (SILENT first), then by number of sites. Give one row to each message or
   enum that the project uses. Messages that an entry selects but that the project never uses can
   share one row for each entry, with their names listed.
4. **Findings.** One sub-section for each catalogue entry that applies, in the order SILENT,
   COMPILE, OUTPUT, GEN. For each site: `path:line`, the quoted line, what happens after the
   upgrade, and the suggested handling. Group sites with the same handling.
5. **Output compatibility.** Each place where the binary or JSON output of the project changes
   (A1, A3, B3, B4, B6, B9, C1 to C8), and what consumes this output if you could find it. Say
   clearly when you could not find the consumer.
6. **Questions for the developer.** What the code cannot answer: can a sender put invalid UTF-8 in
   a string (B2), can a peer send enum values that this schema does not have (B1), is input
   untrusted (B8), does stored data exist in an old JSON form (C7, C8), do other programs depend
   on the exact bytes (section 5).
7. **Checked, not affected.** The catalogue entries that you checked with no finding, one line
   each, with what you searched.
8. **Limits.** What you could not read or decide (generated files that are missing, code behind a
   build option, proto files outside the repository), and that you did not compile or run
   anything.
9. **Suggested order of work.** A short ordered list for the developer: fix GEN items in the
   protos, upgrade and regenerate, fix COMPILE items with the compiler, then go through the SILENT
   sites of section 4, then decide on the OUTPUT items with the owners of the consumers.

Before you answer, check the report against the rules: each finding has a `path:line` and a quote,
nothing in the project was changed, and each catalogue entry is in section 4 or in section 7.
