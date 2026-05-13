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
};

pub fn parse(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    // Increase eval branch quota for types with hundreds of fields
    @setEvalBranchQuota(1000000);

    if (.object_begin != try source.next()) {
        return error.UnexpectedToken;
    }

    // Mainly taken from 0.13.0's source code
    var result: Self = undefined;
    protobuf.internal_init(Self, &result);
    const structInfo = @typeInfo(Self).@"struct";
    var fields_seen = [_]bool{false} ** structInfo.fields.len;

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

        inline for (structInfo.fields, 0..) |field, i| {
            if (comptime !@hasField(@TypeOf(Self._desc_table), field.name)) continue;
            if (field.is_comptime) {
                @compileError("comptime fields are not supported: " ++ @typeName(Self) ++ "." ++ field.name);
            }

            const yes1 = std.mem.eql(u8, field.name, field_name);
            const camel_case_name = comptime to_camel_case(field.name);
            var yes2: bool = undefined;
            if (comptime std.mem.eql(u8, field.name, camel_case_name)) {
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
                    const desc = @field(Self._desc_table, field.name);
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
                                field,
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
                    field,
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
            inline for (structInfo.fields, 0..) |field, i| {
                if (comptime !@hasField(@TypeOf(Self._desc_table), field.name)) continue;
                if (!matched_as_flat_oneof) {
                    const field_descriptor = @field(Self._desc_table, field.name);
                    if (@as(
                        std.meta.Tag(@TypeOf(field_descriptor.ftype)),
                        field_descriptor.ftype,
                    ) == .oneof) {
                        const oneof_type = field_descriptor.ftype.oneof;
                        const union_info = @typeInfo(oneof_type).@"union";
                        inline for (union_info.fields) |union_field| {
                            if (!matched_as_flat_oneof) {
                                const camel = comptime to_camel_case(union_field.name);
                                const matches =
                                    std.mem.eql(u8, union_field.name, field_name) or
                                    std.mem.eql(u8, camel, field_name);
                                if (matches) {
                                    freeAllocated(allocator, name_token.?);
                                    name_token = null;

                                    // Proto3 JSON: for NullValue-typed oneof variants,
                                    // null means set the variant to NULL_VALUE.
                                    // For other types, null clears the active variant.
                                    if (try source.peekNextTokenType() == .null) {
                                        const is_null_value_field = comptime union_field.type == protobuf.wkt.NullValue;
                                        if (comptime is_null_value_field) {
                                            // null JSON for NullValue means NULL_VALUE = 0
                                            _ = try source.next();
                                            @field(&result, field.name) = @unionInit(
                                                oneof_type,
                                                union_field.name,
                                                @as(union_field.type, @enumFromInt(0)),
                                            );
                                            fields_seen[i] = true;
                                            matched_as_flat_oneof = true;
                                            break;
                                        }
                                        // Other types: null clears the active variant.
                                        _ = try source.next();
                                        const is_active = if (@field(&result, field.name)) |cur|
                                            cur == @field(std.meta.Tag(oneof_type), union_field.name)
                                        else
                                            false;
                                        if (is_active) {
                                            @field(&result, field.name) = null;
                                            fields_seen[i] = false;
                                        }
                                        matched_as_flat_oneof = true;
                                        break;
                                    }

                                    // Duplicate oneof variant in same object is an error.
                                    if (fields_seen[i]) {
                                        return error.DuplicateField;
                                    }

                                    @field(&result, field.name) = @unionInit(
                                        oneof_type,
                                        union_field.name,
                                        switch (@field(
                                            oneof_type._desc_table,
                                            union_field.name,
                                        ).ftype) {
                                            .scalar => |scalar| switch (scalar) {
                                                .bytes => try parse_bytes(
                                                    allocator,
                                                    source,
                                                    options,
                                                ),
                                                else => try std.json.innerParse(
                                                    union_field.type,
                                                    allocator,
                                                    source,
                                                    options,
                                                ),
                                            },
                                            .submessage => try std.json.innerParse(
                                                union_field.type,
                                                allocator,
                                                source,
                                                options,
                                            ),
                                            .@"enum" => try parseEnumField(
                                                union_field.type,
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

pub fn decode(
    comptime T: type,
    input: []const u8,
    options: std.json.ParseOptions,
    allocator: std.mem.Allocator,
) !std.json.Parsed(T) {
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
    // Increase eval branch quota for types with hundreds of fields
    @setEvalBranchQuota(1000000);

    // Well-known types (e.g. Duration, Timestamp, wrappers) override jsonStringify
    // to emit their special JSON representation instead of a plain object.
    if (comptime @hasDecl(Self, "jsonStringify")) {
        return self.jsonStringify(jws);
    }

    try jws.beginObject();

    inline for (@typeInfo(Self).@"struct".fields) |fieldInfo| {
        if (comptime !@hasField(@TypeOf(Self._desc_table), fieldInfo.name)) continue;
        const camel_case_name = comptime to_camel_case(fieldInfo.name);
        const descriptor = @field(Self._desc_table, fieldInfo.name);
        const is_oneof = @as(std.meta.Tag(@TypeOf(descriptor.ftype)), descriptor.ftype) == .oneof;

        const field_value = @field(self, fieldInfo.name);
        const field_present = switch (@typeInfo(fieldInfo.type)) {
            .optional => field_value != null,
            // For non-optional fields, skip if value is proto3 default.
            .bool => field_value,
            .int, .float => field_value != 0,
            .@"enum" => @intFromEnum(field_value) != 0,
            .pointer => |ptr| if (ptr.size == .slice) field_value.len != 0 else true,
            .@"struct" => blk: {
                // ArrayList (repeated/map/packed_repeated): skip when empty.
                if (comptime @hasField(fieldInfo.type, "items")) {
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
            inline for (union_info.fields) |union_field| {
                if (value == @field(
                    union_info.tag_type.?,
                    union_field.name,
                )) {
                    const union_camel_case_name = comptime to_camel_case(union_field.name);
                    try jws.objectField(union_camel_case_name);
                    switch (@field(oneof._desc_table, union_field.name).ftype) {
                        .scalar => |scalar| switch (scalar) {
                            .bytes => try print_bytes(@field(value, union_field.name), jws),
                            .string => try jws.write(@field(value, union_field.name)),
                            else => try print_numeric(@field(value, union_field.name), jws),
                        },
                        .@"enum" => try print_numeric(@field(value, union_field.name), jws),
                        .submessage => {
                            const uf = @field(value, union_field.name);
                            if (comptime @typeInfo(union_field.type) == .pointer) {
                                try stringifyOpts(@typeInfo(union_field.type).pointer.child, uf, jws, pb_options);
                            } else {
                                try stringifyOpts(union_field.type, &uf, jws, pb_options);
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
            inline for (union_info.fields) |union_field| {
                if (value == @field(
                    union_info.tag_type.?,
                    union_field.name,
                )) {
                    const union_camel_case_name = comptime to_camel_case(union_field.name);
                    try jws.objectField(union_camel_case_name);
                    switch (@field(oneof._desc_table, union_field.name).ftype) {
                        .scalar => |scalar| switch (scalar) {
                            .bytes => try print_bytes(@field(value, union_field.name), jws),
                            .string => try jws.write(@field(value, union_field.name)),
                            else => try print_numeric(@field(value, union_field.name), jws),
                        },
                        .@"enum" => try print_numeric(@field(value, union_field.name), jws),
                        .submessage => try jws.write(@field(value, union_field.name)),
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
            return @enumFromInt(n);
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
    inline for (@typeInfo(EnumType).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, name)) {
            return @enumFromInt(field.value);
        }
    }
    // Check allow_alias table if present (case-insensitive)
    if (comptime @hasDecl(EnumType, "_json_aliases")) {
        for (EnumType._json_aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(alias.name, name)) {
                return @enumFromInt(alias.value);
            }
        }
    }
    return error.InvalidEnumTag;
}

fn parseStructField(
    comptime T: type,
    result: *T,
    comptime fieldInfo: std.builtin.Type.StructField,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !void {
    @field(result.*, fieldInfo.name) = switch (@field(
        T._desc_table,
        fieldInfo.name,
    ).ftype) {
        .repeated, .packed_repeated => |repeated| list: {
            // repeated T -> ArrayListUnmanaged(T)
            const child_type = @typeInfo(
                fieldInfo.type.Slice,
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
                @TypeOf(@field(result.*, fieldInfo.name)),
            )) {
                .@"union" => @TypeOf(@field(result.*, fieldInfo.name)),
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
            const field_name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                else => {
                    return error.UnexpectedToken;
                },
            };

            inline for (union_info.fields) |union_field| {
                // snake_case comparison
                var this_field = std.mem.eql(u8, union_field.name, field_name);
                if (!this_field) {
                    const union_camel_case_name = comptime to_camel_case(union_field.name);
                    this_field = std.mem.eql(u8, union_camel_case_name, field_name);
                }

                if (this_field) {
                    freeAllocated(allocator, name_token.?);
                    name_token = null;
                    union_value = @unionInit(
                        union_type,
                        union_field.name,
                        switch (@field(
                            oneof._desc_table,
                            union_field.name,
                        ).ftype) {
                            .scalar => |scalar| switch (scalar) {
                                .bytes => try parse_bytes(allocator, source, options),
                                else => try std.json.innerParse(
                                    union_field.type,
                                    allocator,
                                    source,
                                    options,
                                ),
                            },
                            .submessage => other: {
                                break :other try std.json.innerParse(
                                    union_field.type,
                                    allocator,
                                    source,
                                    options,
                                );
                            },
                            .@"enum" => other: {
                                break :other try parseEnumField(
                                    union_field.type,
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
            if (comptime @typeInfo(fieldInfo.type) == .optional) {
                if (try source.peekNextTokenType() == .null) {
                    _ = try source.next();
                    break :blk @as(fieldInfo.type, null);
                }
                const InnerType = @typeInfo(fieldInfo.type).optional.child;
                const v = parseEnumField(InnerType, allocator, source, options) catch |e| {
                    if (e == error.InvalidEnumTag and options.ignore_unknown_fields) break :blk @as(fieldInfo.type, @enumFromInt(0));
                    return e;
                };
                break :blk @as(fieldInfo.type, v);
            }
            const v = parseEnumField(fieldInfo.type, allocator, source, options) catch |e| {
                if (e == error.InvalidEnumTag and options.ignore_unknown_fields) break :blk @as(fieldInfo.type, @enumFromInt(0));
                return e;
            };
            break :blk v;
        },
        .submessage => blk: {
            if (comptime @typeInfo(fieldInfo.type) == .optional) {
                const InnerType = @typeInfo(fieldInfo.type).optional.child;
                if (comptime @typeInfo(InnerType) != .pointer) {
                    if (comptime @hasDecl(InnerType, "jsonParse")) {
                        if (try source.peekNextTokenType() == .null) {
                            const inner = InnerType.jsonParse(allocator, source, options) catch {
                                // The inner type rejected null. Some parsers peek without
                                // consuming on error, so consume the null token if still pending.
                                if (try source.peekNextTokenType() == .null) {
                                    _ = try source.next();
                                }
                                break :blk @as(fieldInfo.type, null);
                            };
                            break :blk @as(fieldInfo.type, inner);
                        }
                    }
                }
            }
            break :blk try std.json.innerParse(fieldInfo.type, allocator, source, options);
        },
        .scalar => |scalar| switch (scalar) {
            .bytes => try parse_bytes(allocator, source, options),
            .float, .double => blk: {
                // Proto3 JSON: reject JSON numbers that overflow to ±inf. However,
                // the string tokens "Infinity", "-Infinity", and "NaN" are valid per spec.
                const next_type = try source.peekNextTokenType();
                const v = try std.json.innerParse(fieldInfo.type, allocator, source, options);
                if (next_type == .number and std.math.isInf(v)) return error.InvalidCharacter;
                break :blk v;
            },
            // `.string`s have their own jsonParse implementation
            // Numeric types will be handled using default std.json parser
            else => try std.json.innerParse(
                fieldInfo.type,
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
            if (s.fields.len != 2) return false;
            return std.mem.eql(u8, s.fields[0].name, "key") and
                std.mem.eql(u8, s.fields[1].name, "value");
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
    fields_seen: *[@typeInfo(T).@"struct".fields.len]bool,
) error{MissingField}!void {
    // Took from std.json source code since it was non-public one
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.defaultValue()) |default| {
                @field(r, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
    }
}
