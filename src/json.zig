const std = @import("std");

const protobuf = @import("protobuf.zig");

/// Options for protobuf JSON serialization.
pub const Options = struct {
    /// Controls oneof encoding format.
    /// - `true` (default): wraps the active oneof variant in an object keyed
    ///   by the oneof field name. Example: `{"someOneof":{"stringInOneof":"x"}}`
    ///   This is the legacy format emitted by previous versions of this library.
    /// - `false`: emits oneof variants as flat fields in the parent object.
    ///   Example: `{"stringInOneof":"x"}` — this matches the protobuf JSON spec.
    emit_oneof_field_name: bool = true,
    /// Known extensions, written as `"[full.name]": value`. Other extensions
    /// are not written, as their name and type are unknown.
    extensions: ?*const protobuf.ExtensionRegistry = null,
};

pub fn parse(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    @setEvalBranchQuota(comptime protobuf.evalBranchQuotaFor(Self));

    if (.object_begin != try source.next()) {
        return error.UnexpectedToken;
    }

    // Mainly taken from 0.13.0's source code
    var result: Self = undefined;
    protobuf.internal_init(Self, &result);
    const structInfo = @typeInfo(Self).@"struct";
    var fields_seen: [structInfo.field_names.len]bool = @splat(false);

    while (true) {
        var name_token: ?std.json.Token = try source.nextAllocMax(
            allocator,
            .alloc_if_needed,
            options.max_value_len.?,
        );
        const field_name = switch (name_token.?) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => { // No more fields.
                break;
            },
            else => {
                return error.UnexpectedToken;
            },
        };

        inline for (structInfo.field_names, structInfo.field_types, structInfo.field_attrs, 0..) |struct_field_name, Field, field_attrs, i| {
            if (comptime !@hasField(@TypeOf(Self._desc_table), struct_field_name)) continue;
            if (field_attrs.@"comptime") {
                @compileError("comptime fields are not supported: " ++ @typeName(Self) ++ "." ++ struct_field_name);
            }

            const yes1 = std.mem.eql(u8, struct_field_name, field_name);
            const camel_case_name = comptime to_camel_case(struct_field_name);
            var yes2: bool = undefined;
            if (comptime std.mem.eql(u8, struct_field_name, camel_case_name)) {
                yes2 = false;
            } else {
                yes2 = std.mem.eql(u8, camel_case_name, field_name);
            }

            if (yes1 and yes2) {
                return error.UnexpectedToken;
            } else if (yes1 or yes2) {
                // Free the name token now in case we're using an
                // allocator that optimizes freeing the last
                // allocated object. (Recursing into innerParse()
                // might trigger more allocations.)
                freeAllocated(allocator, name_token.?);
                name_token = null;

                // Proto3 JSON: null for scalar/repeated/enum fields means "use default", skip it.
                // Submessage fields may have special null semantics (e.g. google.protobuf.Value
                // maps JSON null to null_value kind), so we let parseStructField handle them.
                const skip_null_for_field = comptime blk: {
                    const desc = @field(Self._desc_table, struct_field_name);
                    const tag = @as(std.meta.Tag(@TypeOf(desc.ftype)), desc.ftype);
                    break :blk tag != .submessage;
                };
                if (skip_null_for_field and try source.peekNextTokenType() == .null) {
                    _ = try source.next();
                    break;
                }

                if (fields_seen[i]) {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            // Parse and ignore the redundant value.
                            // We don't want to skip the value,
                            // because we want type checking.
                            try parseStructField(
                                Self,
                                &result,
                                struct_field_name,
                                Field,
                                allocator,
                                source,
                                options,
                            );
                            break;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }
                try parseStructField(
                    Self,
                    &result,
                    struct_field_name,
                    Field,
                    allocator,
                    source,
                    options,
                );
                fields_seen[i] = true;
                break;
            }
        } else {
            // Didn't match any direct struct field.
            // Try flat-oneof format: check if field_name matches any union
            // variant in any oneof field of this struct.
            var matched_as_flat_oneof = false;
            inline for (structInfo.field_names, 0..) |struct_field_name, i| {
                if (comptime !@hasField(@TypeOf(Self._desc_table), struct_field_name)) continue;
                if (!matched_as_flat_oneof) {
                    const field_descriptor = @field(Self._desc_table, struct_field_name);
                    if (@as(
                        std.meta.Tag(@TypeOf(field_descriptor.ftype)),
                        field_descriptor.ftype,
                    ) == .oneof) {
                        const oneof_type = field_descriptor.ftype.oneof;
                        const union_info = @typeInfo(oneof_type).@"union";
                        inline for (union_info.field_names, union_info.field_types) |union_field_name, UnionField| {
                            if (!matched_as_flat_oneof) {
                                const camel = comptime to_camel_case(union_field_name);
                                const matches =
                                    std.mem.eql(u8, union_field_name, field_name) or
                                    std.mem.eql(u8, camel, field_name);
                                if (matches) {
                                    freeAllocated(allocator, name_token.?);
                                    name_token = null;

                                    // Proto3 JSON: for NullValue-typed oneof variants,
                                    // null means set the variant to NULL_VALUE.
                                    // For other types, null clears the active variant.
                                    if (try source.peekNextTokenType() == .null) {
                                        const is_null_value_field = comptime UnionField == protobuf.wkt.NullValue;
                                        if (comptime is_null_value_field) {
                                            // null JSON for NullValue means NULL_VALUE = 0
                                            _ = try source.next();
                                            @field(&result, struct_field_name) = @unionInit(
                                                oneof_type,
                                                union_field_name,
                                                @as(UnionField, @fromBackingInt(@intCast(0))),
                                            );
                                            fields_seen[i] = true;
                                            matched_as_flat_oneof = true;
                                            break;
                                        }
                                        // Other types: null clears the active variant.
                                        _ = try source.next();
                                        const is_active = if (@field(&result, struct_field_name)) |cur|
                                            cur == @field(std.meta.Tag(oneof_type), union_field_name)
                                        else
                                            false;
                                        if (is_active) {
                                            @field(&result, struct_field_name) = null;
                                            fields_seen[i] = false;
                                        }
                                        matched_as_flat_oneof = true;
                                        break;
                                    }

                                    // Duplicate oneof variant in same object is an error.
                                    if (fields_seen[i]) {
                                        return error.DuplicateField;
                                    }

                                    @field(&result, struct_field_name) = @unionInit(
                                        oneof_type,
                                        union_field_name,
                                        switch (@field(
                                            oneof_type._desc_table,
                                            union_field_name,
                                        ).ftype) {
                                            .scalar => |scalar| switch (scalar) {
                                                .bytes => try parse_bytes(
                                                    allocator,
                                                    source,
                                                    options,
                                                ),
                                                else => try std.json.innerParse(
                                                    UnionField,
                                                    allocator,
                                                    source,
                                                    options,
                                                ),
                                            },
                                            .submessage => try std.json.innerParse(
                                                UnionField,
                                                allocator,
                                                source,
                                                options,
                                            ),
                                            .@"enum" => try parseEnumField(
                                                UnionField,
                                                allocator,
                                                source,
                                                options,
                                            ),
                                            .repeated, .packed_repeated => {
                                                @compileError(
                                                    "Repeated fields are not allowed in oneof",
                                                );
                                            },
                                            .oneof => {
                                                @compileError("Nested oneof is not supported");
                                            },
                                        },
                                    );
                                    fields_seen[i] = true;
                                    matched_as_flat_oneof = true;
                                }
                            }
                        }
                    }
                }
            }
            if (!matched_as_flat_oneof) {
                if (comptime @hasField(Self, "_extensions")) {
                    if (try parseExtension(Self, &result, field_name, allocator, source, options)) {
                        freeAllocated(allocator, name_token.?);
                        // Keeps the extensions from being reset to the default.
                        fields_seen[comptime std.meta.fieldIndex(Self, "_extensions").?] = true;
                        continue;
                    }
                }
                freeAllocated(allocator, name_token.?);
                if (options.ignore_unknown_fields) {
                    try source.skipValue();
                } else {
                    return error.UnknownField;
                }
            }
        }
    }
    try fillDefaultStructValues(Self, &result, &fields_seen);
    return result;
}

/// Extensions known while parsing JSON. `jsonParse` cannot carry extra
/// state, so `decodeWithOptions` sets them for the current thread.
threadlocal var tl_extensions: ?*const protobuf.ExtensionRegistry = null;

/// `DecodeOptions.recursion_limit` of the JSON being parsed on this thread,
/// set by `decodeWithOptions` like `tl_extensions`.
threadlocal var tl_recursion_limit: u32 = protobuf.wire.default_recursion_limit;

/// How deeply values that nest by themselves (`google.protobuf.Value`) may
/// nest in the JSON being parsed on this thread: the `recursion_limit` given
/// to `decodeWithOptions`, else the default.
pub fn recursionLimit() u32 {
    return tl_recursion_limit;
}

/// Parses the value of the key `name` as an extension of `Self`, if `name` is
/// the `[full.name]` of a known extension. Returns whether it did.
fn parseExtension(
    comptime Self: type,
    result: *Self,
    name: []const u8,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !bool {
    const registry = tl_extensions orelse return false;
    if (name.len < 2 or name[0] != '[' or name[name.len - 1] != ']') return false;
    const entry = registry.findByName(Self, name[1 .. name.len - 1]) orelse return false;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const text = try nextValueText(arena.allocator(), source, options);
    const records = entry.from_json(text, allocator, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnexpectedToken,
    };
    defer allocator.free(records);
    try protobuf.extension.replaceField(allocator, &result._extensions, entry.field_number, records);
    return true;
}

/// Consumes the next value of `source` and returns its JSON text, which is
/// either part of the input or allocated with `arena`.
fn nextValueText(arena: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) ![]const u8 {
    if (@TypeOf(source.*) == std.json.Scanner and source.is_end_of_input) {
        // The scanner holds the whole input: the value is used as written.
        _ = try source.peekNextTokenType(); // Moves to the start of the value.
        const start = source.cursor;
        try source.skipValue();
        return source.input[start..source.cursor];
    }
    // Streamed input is not kept, so the value is parsed and written back.
    const value = try std.json.innerParse(std.json.Value, arena, source, options);
    return std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;
}

/// Writes the known extensions set in `records` as `"[full.name]": value`.
fn writeExtensions(
    comptime Self: type,
    records: []const u8,
    jws: anytype,
    opts: Options,
    registry: *const protobuf.ExtensionRegistry,
) !void {
    if (records.len == 0) return;
    const allocator = protobuf.wkt.tl_any_alloc orelse return error.WriteFailed;
    const known = registry.of(Self);
    if (known.len == 0) return;

    var fallback_buffer: [64]u8 = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&fallback_buffer, allocator);
    const bits_allocator = fallback.allocator();
    var present = protobuf.extension.presentEntries(bits_allocator, known, records) catch return error.WriteFailed;
    defer present.deinit(bits_allocator);
    var it = present.iterator(.{});
    while (it.next()) |index| {
        const entry = known[index];
        const text = (entry.to_json(records, allocator, opts) catch return error.WriteFailed) orelse continue;
        defer allocator.free(text);
        const key = std.fmt.allocPrint(allocator, "[{s}]", .{entry.full_name}) catch return error.WriteFailed;
        defer allocator.free(key);
        try jws.objectField(key);
        try jws.beginWriteRaw();
        try jws.writer.writeAll(text);
        jws.endWriteRaw();
    }
}

/// Like `decode`, with protobuf specific options: `[full.name]` keys of the
/// known extensions are decoded as extensions.
pub fn decodeWithOptions(
    comptime T: type,
    input: []const u8,
    options: std.json.ParseOptions,
    pb_options: protobuf.DecodeOptions,
    allocator: std.mem.Allocator,
) !std.json.Parsed(T) {
    const previous = tl_extensions;
    tl_extensions = pb_options.extensions;
    defer tl_extensions = previous;
    const previous_limit = tl_recursion_limit;
    tl_recursion_limit = pb_options.recursion_limit;
    defer tl_recursion_limit = previous_limit;
    return decode(T, input, options, allocator);
}

pub fn decode(
    comptime T: type,
    input: []const u8,
    options: std.json.ParseOptions,
    allocator: std.mem.Allocator,
) !std.json.Parsed(T) {
    @setEvalBranchQuota(comptime protobuf.evalBranchQuotaFor(T));

    const parsed = try std.json.parseFromSlice(T, allocator, input, options);
    return parsed;
}

pub fn encode(
    data: anytype,
    std_options: std.json.Stringify.Options,
    pb_options: Options,
    allocator: std.mem.Allocator,
) ![]u8 {
    const DataType = @TypeOf(data);
    @setEvalBranchQuota(comptime protobuf.evalBranchQuotaFor(DataType));

    const CustomEncoder = struct {
        inner: DataType,
        opts: Options,
        pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
            return stringifyOpts(DataType, &self.inner, jws, self.opts);
        }
    };
    // Set thread-local allocator for Any.jsonStringify.
    const prev_alloc = protobuf.wkt.tl_any_alloc;
    protobuf.wkt.tl_any_alloc = allocator;
    defer protobuf.wkt.tl_any_alloc = prev_alloc;
    return std.json.Stringify.valueAlloc(
        allocator,
        CustomEncoder{ .inner = data, .opts = pb_options },
        std_options,
    );
}

fn stringifyOpts(Self: type, self: *const Self, jws: anytype, opts: Options) std.meta.Child(@TypeOf(jws)).Error!void {
    @setEvalBranchQuota(comptime protobuf.evalBranchQuotaFor(Self));

    // Well-known types (e.g. Duration, Timestamp, wrappers) override jsonStringify
    // to emit their special JSON representation instead of a plain object.
    if (comptime @hasDecl(Self, "jsonStringify")) {
        return self.jsonStringify(jws);
    }

    try jws.beginObject();

    const struct_info = @typeInfo(Self).@"struct";
    inline for (struct_info.field_names, struct_info.field_types) |field_name, Field| {
        if (comptime !@hasField(@TypeOf(Self._desc_table), field_name)) continue;
        const camel_case_name = comptime to_camel_case(field_name);
        const descriptor = @field(Self._desc_table, field_name);
        const is_oneof = @as(std.meta.Tag(@TypeOf(descriptor.ftype)), descriptor.ftype) == .oneof;

        const field_value = @field(self, field_name);
        // Required fields are always written, even when holding zero.
        const field_present = descriptor.features.legacy_required or switch (@typeInfo(Field)) {
            .optional => field_value != null,
            // For non-optional fields, skip if value is proto3 default.
            .bool => field_value,
            .int, .float => field_value != 0,
            .@"enum" => field_value != comptime protobuf.enumDefault(Field),
            .pointer => |ptr| if (ptr.size == .slice) field_value.len != 0 else true,
            .@"struct" => blk: {
                // ArrayList (repeated/map/packed_repeated): skip when empty.
                if (comptime @hasField(Field, "items")) {
                    break :blk field_value.items.len != 0;
                }
                break :blk true;
            },
            else => true,
        };

        if (field_present) {
            // For oneof fields in flat mode, skip writing the container field name.
            // The variant name will be written directly into the parent object by
            // stringify_struct_field_with_options.
            if (!is_oneof or opts.emit_oneof_field_name) {
                try jws.objectField(camel_case_name);
            }
            try stringify_struct_field_with_options(
                field_value,
                descriptor,
                jws,
                opts,
            );
        }
        // null optionals (including null oneofs): skip entirely
    }

    if (comptime @hasField(Self, "_extensions")) {
        if (opts.extensions) |registry| {
            try writeExtensions(Self, self._extensions.records, jws, opts, registry);
        }
    }

    try jws.endObject();
}

fn to_camel_case(not_camel_cased_string: []const u8) []const u8 {
    // Matches protobuf's ToJsonName (descriptor.cc): underscores are consumed
    // and the following character is uppercased. The first character is NOT
    // lowercased — fields like `_field_name3` produce `FieldName3`, not `fieldName3`.
    comptime var capitalize_next_letter = false;
    comptime var camel_cased_string: []const u8 = "";

    inline for (not_camel_cased_string) |char| {
        if (char == '_') {
            capitalize_next_letter = true;
        } else if (capitalize_next_letter) {
            camel_cased_string = camel_cased_string ++ .{
                comptime std.ascii.toUpper(char),
            };
            capitalize_next_letter = false;
        } else {
            camel_cased_string = camel_cased_string ++ .{char};
        }
    }

    return camel_cased_string;
}

fn freeAllocated(allocator: std.mem.Allocator, token: std.json.Token) void {
    // Took from std.json source code since it was non-public one
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

fn stringify_struct_field_with_options(
    struct_field: anytype,
    field_descriptor: protobuf.FieldDescriptor,
    jws: anytype,
    pb_options: Options,
) !void {
    var value: switch (@typeInfo(@TypeOf(struct_field))) {
        .optional => |optional| optional.child,
        else => @TypeOf(struct_field),
    } = undefined;

    switch (@typeInfo(@TypeOf(struct_field))) {
        .optional => {
            if (struct_field) |v| {
                value = v;
            } else return;
        },
        else => {
            value = struct_field;
        },
    }

    switch (field_descriptor.ftype) {
        .scalar => |scalar| switch (scalar) {
            .bytes => try print_bytes(value, jws),
            .string => try jws.write(value),
            else => try print_numeric(value, jws),
        },
        .@"enum" => try print_numeric(value, jws),
        .repeated, .packed_repeated => |repeated| {
            const slice = value.items;
            const Elem = std.meta.Elem(@TypeOf(slice));
            if (comptime isMapEntry(Elem)) {
                // Proto3: duplicate map keys use last-wins semantics.
                try jws.beginObject();
                for (slice, 0..) |entry, i| {
                    var is_dup = false;
                    for (slice[i + 1 ..]) |later| {
                        if (mapKeyEq(entry.key, later.key)) {
                            is_dup = true;
                            break;
                        }
                    }
                    if (is_dup) continue;
                    try stringifyMapKey(entry.key, jws);
                    // Map values must always produce a JSON value. For a null optional
                    // submessage (missing default), emit the empty message {}.
                    if (comptime @typeInfo(@TypeOf(entry.value)) == .optional) {
                        if (entry.value == null) {
                            try jws.beginObject();
                            try jws.endObject();
                            continue;
                        }
                    }
                    try stringify_struct_field_with_options(
                        entry.value,
                        @field(Elem._desc_table, "value"),
                        jws,
                        pb_options,
                    );
                }
                try jws.endObject();
            } else {
                try jws.beginArray();
                for (slice) |el| {
                    switch (repeated) {
                        .scalar => |scalar| switch (scalar) {
                            .bytes => try print_bytes(el, jws),
                            .string => try jws.write(el),
                            else => try print_numeric(el, jws),
                        },
                        .@"enum" => try print_numeric(el, jws),
                        .submessage => try stringifyOpts(@TypeOf(el), &el, jws, pb_options),
                    }
                }
                try jws.endArray();
            }
        },
        .oneof => |oneof| {
            const union_info = @typeInfo(@TypeOf(value)).@"union";
            if (union_info.tag_type == null) {
                @compileError("Untagged unions are not supported here");
            }

            if (pb_options.emit_oneof_field_name) {
                try jws.beginObject();
            }
            inline for (union_info.field_names, union_info.field_types) |union_field_name, UnionField| {
                if (value == @field(
                    union_info.tag_type.?,
                    union_field_name,
                )) {
                    const union_camel_case_name = comptime to_camel_case(union_field_name);
                    try jws.objectField(union_camel_case_name);
                    switch (@field(oneof._desc_table, union_field_name).ftype) {
                        .scalar => |scalar| switch (scalar) {
                            .bytes => try print_bytes(@field(value, union_field_name), jws),
                            .string => try jws.write(@field(value, union_field_name)),
                            else => try print_numeric(@field(value, union_field_name), jws),
                        },
                        .@"enum" => try print_numeric(@field(value, union_field_name), jws),
                        .submessage => {
                            const uf = @field(value, union_field_name);
                            if (comptime @typeInfo(UnionField) == .pointer) {
                                try stringifyOpts(@typeInfo(UnionField).pointer.child, uf, jws, pb_options);
                            } else {
                                try stringifyOpts(UnionField, &uf, jws, pb_options);
                            }
                        },
                        .repeated, .packed_repeated => {
                            @compileError("Repeated fields are not allowed in oneof");
                        },
                        .oneof => {
                            @compileError("one oneof inside another? really?");
                        },
                    }
                    break;
                }
            } else unreachable;

            if (pb_options.emit_oneof_field_name) {
                try jws.endObject();
            }
        },
        .submessage => {
            const V = @TypeOf(value);
            if (comptime @typeInfo(V) == .pointer) {
                try stringifyOpts(@typeInfo(V).pointer.child, value, jws, pb_options);
            } else {
                try stringifyOpts(V, &value, jws, pb_options);
            }
        },
    }
}

fn stringify_struct_field(
    struct_field: anytype,
    field_descriptor: protobuf.FieldDescriptor,
    jws: anytype,
) !void {
    var value: switch (@typeInfo(@TypeOf(struct_field))) {
        .optional => |optional| optional.child,
        else => @TypeOf(struct_field),
    } = undefined;

    switch (@typeInfo(@TypeOf(struct_field))) {
        .optional => {
            if (struct_field) |v| {
                value = v;
            } else return;
        },
        else => {
            value = struct_field;
        },
    }

    switch (field_descriptor.ftype) {
        .scalar => |scalar| switch (scalar) {
            .bytes => try print_bytes(value, jws),
            // `.string`s have their own jsonStringify implementation
            .string => try jws.write(value),
            else => try print_numeric(value, jws),
        },
        .@"enum" => try print_numeric(value, jws),
        .repeated, .packed_repeated => |repeated| {
            // ArrayListUnmanaged
            const slice = value.items;
            try jws.beginArray();
            for (slice) |el| {
                switch (repeated) {
                    .scalar => |scalar| switch (scalar) {
                        .bytes => try print_bytes(el, jws),
                        .string => try jws.write(el),
                        else => try print_numeric(el, jws),
                    },
                    .@"enum" => try print_numeric(el, jws),
                    .submessage => try jws.write(el),
                }
            }
            try jws.endArray();
        },
        .oneof => |oneof| {
            // Tagged union type
            const union_info = @typeInfo(@TypeOf(value)).@"union";
            if (union_info.tag_type == null) {
                @compileError("Untagged unions are not supported here");
            }

            try jws.beginObject();
            inline for (union_info.field_names) |union_field_name| {
                if (value == @field(
                    union_info.tag_type.?,
                    union_field_name,
                )) {
                    const union_camel_case_name = comptime to_camel_case(union_field_name);
                    try jws.objectField(union_camel_case_name);
                    switch (@field(oneof._desc_table, union_field_name).ftype) {
                        .scalar => |scalar| switch (scalar) {
                            .bytes => try print_bytes(@field(value, union_field_name), jws),
                            .string => try jws.write(@field(value, union_field_name)),
                            else => try print_numeric(@field(value, union_field_name), jws),
                        },
                        .@"enum" => try print_numeric(@field(value, union_field_name), jws),
                        .submessage => try jws.write(@field(value, union_field_name)),
                        .repeated, .packed_repeated => {
                            @compileError("Repeated fields are not allowed in oneof");
                        },
                        .oneof => {
                            @compileError("one oneof inside another? really?");
                        },
                    }
                    break;
                }
            } else unreachable;

            try jws.endObject();
        },
        .submessage => {
            // `.submessage`s (generated structs) have their own jsonStringify implementation
            try jws.write(value);
        },
    }
}

/// Parse a protobuf enum field from JSON.
/// Accepts both integer values and string names (case-insensitive per proto3 JSON spec).
/// When options.ignore_unknown_fields is true, unknown string names return the default (0).
fn parseEnumField(comptime EnumType: type, allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !EnumType {
    switch (try source.peekNextTokenType()) {
        .number => {
            const tag_type = @typeInfo(EnumType).@"enum".tag_type;
            const n = try std.json.innerParse(tag_type, allocator, source, options);
            // Closed enums are exhaustive and only accept known values.
            if (comptime @typeInfo(EnumType).@"enum".mode == .exhaustive) {
                return std.enums.fromInt(EnumType, n) orelse error.InvalidEnumTag;
            }
            return @fromBackingInt(@intCast(n));
        },
        else => {},
    }
    const name_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer freeAllocated(allocator, name_token);
    const name = switch (name_token) {
        inline .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };
    if (std.meta.stringToEnum(EnumType, name)) |v| return v;
    // Case-insensitive fallback over enum fields (handles "moo" → MOO)
    const enum_info = @typeInfo(EnumType).@"enum";
    inline for (enum_info.field_names, enum_info.field_values) |field_name, field_value| {
        if (std.ascii.eqlIgnoreCase(field_name, name)) {
            return @fromBackingInt(@intCast(field_value));
        }
    }
    // Check allow_alias table if present (case-insensitive)
    if (comptime @hasDecl(EnumType, "_json_aliases")) {
        for (EnumType._json_aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(alias.name, name)) {
                return @fromBackingInt(@intCast(alias.value));
            }
        }
    }
    return error.InvalidEnumTag;
}

fn parseStructField(
    comptime T: type,
    result: *T,
    comptime field_name: []const u8,
    comptime Field: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !void {
    @field(result.*, field_name) = switch (@field(
        T._desc_table,
        field_name,
    ).ftype) {
        .repeated, .packed_repeated => |repeated| list: {
            // repeated T -> ArrayListUnmanaged(T)
            const child_type = @typeInfo(
                Field.Slice,
            ).pointer.child;

            // Map fields are encoded as JSON objects; regular repeated as arrays.
            if (comptime isMapEntry(child_type)) {
                if (.object_begin != try source.next()) return error.UnexpectedToken;
                var array_list: std.ArrayList(child_type) = .empty;
                while (true) {
                    const key_token = try source.nextAllocMax(
                        allocator,
                        .alloc_if_needed,
                        options.max_value_len.?,
                    );
                    const key_str = switch (key_token) {
                        inline .string, .allocated_string => |s| s,
                        .object_end => break,
                        else => return error.UnexpectedToken,
                    };
                    defer freeAllocated(allocator, key_token);

                    const KeyType = @TypeOf(@as(child_type, undefined).key);
                    const ValueType = @TypeOf(@as(child_type, undefined).value);
                    const parsed_key: KeyType = switch (comptime @typeInfo(KeyType)) {
                        .bool => if (std.mem.eql(u8, key_str, "true"))
                            true
                        else if (std.mem.eql(u8, key_str, "false"))
                            false
                        else
                            return error.UnexpectedToken,
                        .int => std.fmt.parseInt(KeyType, key_str, 10) catch
                            return error.UnexpectedToken,
                        .pointer => try allocator.dupe(u8, key_str),
                        else => return error.UnexpectedToken,
                    };
                    // For enum map values, use parseEnumField for alias/case support.
                    const parsed_value: ValueType = if (comptime @typeInfo(ValueType) == .@"enum") val: {
                        break :val parseEnumField(ValueType, allocator, source, options) catch |e| {
                            if (e == error.InvalidEnumTag and options.ignore_unknown_fields) {
                                // Skip map entries with unknown enum values
                                if (comptime @typeInfo(KeyType) == .pointer) allocator.free(parsed_key);
                                continue;
                            }
                            return e;
                        };
                    } else try std.json.innerParse(ValueType, allocator, source, options);
                    try array_list.append(allocator, .{ .key = parsed_key, .value = parsed_value });
                }
                break :list array_list;
            }

            switch (try source.peekNextTokenType()) {
                .array_begin => {
                    std.debug.assert(.array_begin == try source.next());
                    var array_list: std.ArrayList(child_type) = .empty;
                    while (true) {
                        if (.array_end == try source.peekNextTokenType()) {
                            _ = try source.next();
                            break;
                        }
                        switch (repeated) {
                            .scalar => |scalar| {
                                try array_list.ensureUnusedCapacity(allocator, 1);
                                array_list.appendAssumeCapacity(switch (scalar) {
                                    .bytes => try parse_bytes(allocator, source, options),
                                    else => try std.json.innerParse(child_type, allocator, source, options),
                                });
                            },
                            .submessage => {
                                try array_list.ensureUnusedCapacity(allocator, 1);
                                array_list.appendAssumeCapacity(try std.json.innerParse(child_type, allocator, source, options));
                            },
                            .@"enum" => {
                                const v = parseEnumField(child_type, allocator, source, options) catch |e| {
                                    if (e == error.InvalidEnumTag and options.ignore_unknown_fields) continue;
                                    return e;
                                };
                                try array_list.ensureUnusedCapacity(allocator, 1);
                                array_list.appendAssumeCapacity(v);
                            },
                        }
                    }
                    break :list array_list;
                },
                else => return error.UnexpectedToken,
            }
        },
        .oneof => |oneof| oneof: {
            // oneof -> union
            var union_value: switch (@typeInfo(
                @TypeOf(@field(result.*, field_name)),
            )) {
                .@"union" => @TypeOf(@field(result.*, field_name)),
                .optional => |optional| optional.child,
                else => unreachable,
            } = undefined;

            const union_type = @TypeOf(union_value);
            const union_info = @typeInfo(union_type).@"union";
            if (union_info.tag_type == null) {
                @compileError("Untagged unions are not supported here");
            }

            if (.object_begin != try source.next()) {
                return error.UnexpectedToken;
            }

            var name_token: ?std.json.Token = try source.nextAllocMax(
                allocator,
                .alloc_if_needed,
                options.max_value_len.?,
            );
            const json_field_name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                else => {
                    return error.UnexpectedToken;
                },
            };

            inline for (union_info.field_names, union_info.field_types) |union_field_name, UnionField| {
                // snake_case comparison
                var this_field = std.mem.eql(u8, union_field_name, json_field_name);
                if (!this_field) {
                    const union_camel_case_name = comptime to_camel_case(union_field_name);
                    this_field = std.mem.eql(u8, union_camel_case_name, json_field_name);
                }

                if (this_field) {
                    freeAllocated(allocator, name_token.?);
                    name_token = null;
                    union_value = @unionInit(
                        union_type,
                        union_field_name,
                        switch (@field(
                            oneof._desc_table,
                            union_field_name,
                        ).ftype) {
                            .scalar => |scalar| switch (scalar) {
                                .bytes => try parse_bytes(allocator, source, options),
                                else => try std.json.innerParse(
                                    UnionField,
                                    allocator,
                                    source,
                                    options,
                                ),
                            },
                            .submessage => other: {
                                break :other try std.json.innerParse(
                                    UnionField,
                                    allocator,
                                    source,
                                    options,
                                );
                            },
                            .@"enum" => other: {
                                break :other try parseEnumField(
                                    UnionField,
                                    allocator,
                                    source,
                                    options,
                                );
                            },
                            .repeated, .packed_repeated => {
                                @compileError("Repeated fields are not allowed in oneof");
                            },
                            .oneof => {
                                @compileError("one oneof inside another? really?");
                            },
                        },
                    );
                    if (.object_end != try source.next()) {
                        return error.UnexpectedToken;
                    }
                    break :oneof union_value;
                }
            } else return error.UnknownField;
        },
        // `.submessage`s (generated structs) have their own jsonParse implementation.
        // For optional submessages, if the next JSON token is null, let the inner type's
        // jsonParse handle it (e.g. google.protobuf.Value maps null → null_value kind).
        // If the inner type's jsonParse rejects null, fall back to returning null (absent).
        .@"enum" => blk: {
            if (comptime @typeInfo(Field) == .optional) {
                if (try source.peekNextTokenType() == .null) {
                    _ = try source.next();
                    break :blk @as(Field, null);
                }
                const InnerType = @typeInfo(Field).optional.child;
                const v = parseEnumField(InnerType, allocator, source, options) catch |e| {
                    // An ignored unknown value leaves the field unset.
                    if (e == error.InvalidEnumTag and options.ignore_unknown_fields) break :blk @as(Field, null);
                    return e;
                };
                break :blk @as(Field, v);
            }
            const v = parseEnumField(Field, allocator, source, options) catch |e| {
                if (e == error.InvalidEnumTag and options.ignore_unknown_fields) break :blk protobuf.enumDefault(Field);
                return e;
            };
            break :blk v;
        },
        .submessage => blk: {
            if (comptime @typeInfo(Field) == .optional) {
                const InnerType = @typeInfo(Field).optional.child;
                if (comptime @typeInfo(InnerType) != .pointer) {
                    if (comptime @hasDecl(InnerType, "jsonParse")) {
                        if (try source.peekNextTokenType() == .null) {
                            const inner = InnerType.jsonParse(allocator, source, options) catch {
                                // The inner type rejected null. Some parsers peek without
                                // consuming on error, so consume the null token if still pending.
                                if (try source.peekNextTokenType() == .null) {
                                    _ = try source.next();
                                }
                                break :blk @as(Field, null);
                            };
                            break :blk @as(Field, inner);
                        }
                    }
                }
            }
            break :blk try std.json.innerParse(Field, allocator, source, options);
        },
        .scalar => |scalar| switch (scalar) {
            .bytes => try parse_bytes(allocator, source, options),
            .float, .double => blk: {
                // Proto3 JSON: reject JSON numbers that overflow to ±inf. However,
                // the string tokens "Infinity", "-Infinity", and "NaN" are valid per spec.
                const next_type = try source.peekNextTokenType();
                const v = try std.json.innerParse(Field, allocator, source, options);
                // Fields with explicit presence are optional floats.
                const float = if (comptime @typeInfo(Field) == .optional)
                    v orelse break :blk v
                else
                    v;
                if (next_type == .number and std.math.isInf(float)) return error.InvalidCharacter;
                break :blk v;
            },
            // `.string`s have their own jsonParse implementation
            // Numeric types will be handled using default std.json parser
            else => try std.json.innerParse(
                Field,
                allocator,
                source,
                options,
            ),
        },
        // TODO: ATM there's no support for Timestamp, Duration
        //   and some other protobuf types (see progress at
        //   https://github.com/Arwalk/zig-protobuf/pull/49)
        //   so it's better to see "switch must handle all possibilities"
        //   compiler error here and then add JSON (de)serialization support
        //   for them than hope that default std.json (de)serializer
        //   will make all right by its own
    };
}

fn print_numeric(value: anytype, jws: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .float, .comptime_float => {},
        .int => |info| {
            // Proto3 JSON: 64-bit integers must be encoded as strings.
            if (info.bits == 64) {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{}", .{value}) catch unreachable;
                try jws.write(s);
                return;
            }
            try jws.write(value);
            return;
        },
        .@"enum" => {
            if (comptime std.meta.hasFn(@TypeOf(value), "jsonStringify")) {
                return value.jsonStringify(jws);
            }
            try jws.write(value);
            return;
        },
        .comptime_int, .bool => {
            try jws.write(value);
            return;
        },
        else => @compileError("Float/integer expected but " ++ @typeName(@TypeOf(value)) ++ " given"),
    }

    if (std.math.isNan(value)) {
        try jws.write("NaN");
    } else if (std.math.isPositiveInf(value)) {
        try jws.write("Infinity");
    } else if (std.math.isNegativeInf(value)) {
        try jws.write("-Infinity");
    } else {
        try jws.write(value);
    }
}

fn isMapEntry(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.field_names.len != 2) return false;
            return std.mem.eql(u8, s.field_names[0], "key") and
                std.mem.eql(u8, s.field_names[1], "value");
        },
        else => return false,
    }
}

fn stringifyMapKey(key: anytype, jws: anytype) !void {
    switch (comptime @typeInfo(@TypeOf(key))) {
        .bool => try jws.objectField(if (key) "true" else "false"),
        .int => {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{key}) catch unreachable;
            try jws.objectField(s);
        },
        .pointer => try jws.objectField(key), // []const u8 string key
        else => @compileError("unsupported map key type: " ++ @typeName(@TypeOf(key))),
    }
}

fn mapKeyEq(a: anytype, b: @TypeOf(a)) bool {
    switch (comptime @typeInfo(@TypeOf(a))) {
        .bool, .int => return a == b,
        .pointer => return std.mem.eql(u8, a, b),
        else => return false,
    }
}

fn print_bytes(value: anytype, jws: anytype) !void {
    try jsonValueStartAssumeTypeOk(jws);
    try jws.writer.writeByte('"');

    try std.base64.standard.Encoder.encodeWriter(jws.writer, value);

    try jws.writer.writeByte('"');

    jws.next_punctuation = .comma;
}

fn jsonIndent(jws: anytype) !void {
    var char: u8 = ' ';
    const n_chars = switch (jws.options.whitespace) {
        .minified => return,
        .indent_1 => 1 * jws.indent_level,
        .indent_2 => 2 * jws.indent_level,
        .indent_3 => 3 * jws.indent_level,
        .indent_4 => 4 * jws.indent_level,
        .indent_8 => 8 * jws.indent_level,
        .indent_tab => blk: {
            char = '\t';
            break :blk jws.indent_level;
        },
    };
    try jws.writer.writeByte('\n');
    try jws.writer.splatByteAll(char, n_chars);
}

fn jsonIsComplete(jws: anytype) bool {
    return jws.indent_level == 0 and jws.next_punctuation == .comma;
}

fn jsonValueStartAssumeTypeOk(jws: anytype) !void {
    std.debug.assert(!jsonIsComplete(jws));
    switch (jws.next_punctuation) {
        .the_beginning => {
            // No indentation for the very beginning.
        },
        .none => {
            // First item in a container.
            try jsonIndent(jws);
        },
        .comma => {
            // Subsequent item in a container.
            try jws.writer.writeByte(',');
            try jsonIndent(jws);
        },
        .colon => {
            try jws.writer.writeByte(':');
            if (jws.options.whitespace != .minified) {
                try jws.writer.writeByte(' ');
            }
        },
    }
}

fn base64ErrorToJsonParseError(err: std.base64.Error) std.json.ParseFromValueError {
    return switch (err) {
        std.base64.Error.NoSpaceLeft => std.json.ParseFromValueError.Overflow,
        std.base64.Error.InvalidPadding,
        std.base64.Error.InvalidCharacter,
        => std.json.ParseFromValueError.UnexpectedToken,
    };
}

/// Decode a base64 character (standard or url-safe). Returns 64 for '=', 255 for invalid.
fn decodeBase64Char(c: u8) u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+', '-' => 62, // standard '+' and url-safe '-'
        '/', '_' => 63, // standard '/' and url-safe '_'
        '=' => 64, // padding
        else => 255,
    };
}

/// Lenient base64/base64url decoder. Accepts standard and url-safe characters,
/// with or without padding, and ignores non-zero trailing bits.
pub fn decodeBase64Lenient(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Strip optional trailing '=' padding
    var stripped = input;
    while (stripped.len > 0 and stripped[stripped.len - 1] == '=') {
        stripped = stripped[0 .. stripped.len - 1];
    }
    // Output size: floor(len * 6 / 8)
    const out_len = stripped.len * 6 / 8;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i + 1 < stripped.len) : (i += 4) {
        const remaining = stripped.len - i;
        const a = decodeBase64Char(stripped[i]);
        if (a >= 64) return error.UnexpectedToken;
        if (remaining == 1) break;
        const b = decodeBase64Char(stripped[i + 1]);
        if (b >= 64) return error.UnexpectedToken;
        out[out_idx] = (a << 2) | (b >> 4);
        out_idx += 1;
        if (remaining == 2) break;
        const c = decodeBase64Char(stripped[i + 2]);
        if (c >= 64) return error.UnexpectedToken;
        out[out_idx] = (b << 4) | (c >> 2);
        out_idx += 1;
        if (remaining == 3) break;
        const d = decodeBase64Char(stripped[i + 3]);
        if (d >= 64) return error.UnexpectedToken;
        out[out_idx] = (c << 6) | d;
        out_idx += 1;
    }
    return out[0..out_idx];
}

fn parse_bytes(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) ![]const u8 {
    const temp_raw = try std.json.innerParse([]u8, allocator, source, options);
    defer allocator.free(temp_raw);
    return decodeBase64Lenient(allocator, temp_raw) catch error.UnexpectedToken;
}

fn fillDefaultStructValues(
    comptime T: type,
    r: *T,
    fields_seen: *[@typeInfo(T).@"struct".field_names.len]bool,
) error{MissingField}!void {
    // Took from std.json source code since it was non-public one
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.field_names, struct_info.field_types, struct_info.field_attrs, 0..) |field_name, Field, field_attrs, i| {
        if (!fields_seen[i]) {
            if (field_attrs.defaultValue(Field)) |default| {
                @field(r, field_name) = default;
            } else {
                return error.MissingField;
            }
        }
    }
}
