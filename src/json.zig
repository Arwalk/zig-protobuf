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
    /// Controls whether fields with default values are included in JSON output.
    /// - `false` (default, spec-conformant): omits fields that equal their proto3
    ///   default value (0 for numerics, false for bools, "" for strings, empty
    ///   for repeated/map). This matches the protobuf JSON specification.
    /// - `true`: emits all fields regardless of value (backward compatible).
    emit_default_values: bool = false,
};

pub fn parse(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    // Increase eval branch quota for types with hundreds of fields
    @setEvalBranchQuota(1000000);

    // Well-known types have custom JSON representations per the proto3 spec
    if (comptime @hasDecl(Self, "_well_known_type")) {
        return parseWellKnownType(Self, allocator, source, options);
    }

    if (.object_begin != try source.next()) {
        return error.UnexpectedToken;
    }

    // Mainly taken from 0.13.0's source code
    var result: Self = undefined;
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

                                    // Handle null: per proto3 spec, null for a oneof
                                    // variant means "this variant is not set", except
                                    // for NullValue enum fields where null maps to NULL_VALUE.
                                    if (.null == try source.peekNextTokenType()) {
                                        _ = try source.next();
                                        const is_null_value = comptime blk: {
                                            if (@typeInfo(union_field.type) != .@"enum") break :blk false;
                                            break :blk @hasField(union_field.type, "NULL_VALUE");
                                        };
                                        if (is_null_value) {
                                            @field(&result, field.name) = @unionInit(
                                                oneof_type,
                                                union_field.name,
                                                @field(union_field.type, "NULL_VALUE"),
                                            );
                                        }
                                        // For non-NullValue types: don't modify the oneof -
                                        // null just means "this particular variant is absent"
                                    } else {
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
                                                .submessage, .@"enum" => try std.json.innerParse(
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
                                    }
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

    // We can't use the standard jsonStringify interface because std.json.Stringify
    // constrains the error set to {WriteFailed}. Our WKT serializers need to return
    // RangeError for spec validation failures. So we drive the Stringify directly.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: std.json.Stringify = .{ .writer = &aw.writer, .options = std_options };

    try stringifyOpts(DataType, &data, &jws, pb_options);

    return aw.toOwnedSlice();
}

/// Checks whether a field value equals its proto3 default.
/// Used to suppress default-valued fields in JSON output per the protobuf spec.
/// This is comptime-dispatched based on the field descriptor type, so there is
/// zero runtime overhead for the type dispatch itself.
fn isDefaultValue(value: anytype, comptime field_desc: protobuf.FieldDescriptor) bool {
    return switch (field_desc.ftype) {
        .scalar => |scalar| switch (scalar) {
            .string, .bytes => value.len == 0,
            .bool => value == false,
            .float => @as(u32, @bitCast(value)) == 0,
            .double => @as(u64, @bitCast(value)) == 0,
            else => value == 0,
        },
        .@"enum" => @intFromEnum(value) == 0,
        .repeated, .packed_repeated => value.items.len == 0,
        // Non-optional submessages are always emitted. In proto3, submessages
        // are generated as optional (?T) and handled by the null check in
        // stringifyOpts, so this case is only reached for non-optional value
        // types which should always be present.
        .submessage => false,
        // Oneofs are always generated as optional (?union) and handled by the
        // null check in stringifyOpts. This case is unreachable in normal use.
        .oneof => false,
    };
}

fn stringifyOpts(Self: type, self: *const Self, jws: anytype, opts: Options) !void {
    // Increase eval branch quota for types with hundreds of fields
    @setEvalBranchQuota(1000000);

    // Well-known types have custom JSON representations per the proto3 spec
    if (comptime @hasDecl(Self, "_well_known_type")) {
        return stringifyWellKnownType(Self, self, jws, opts);
    }

    try jws.beginObject();

    inline for (@typeInfo(Self).@"struct".fields) |fieldInfo| {
        const camel_case_name = comptime to_camel_case(fieldInfo.name);
        const descriptor = @field(Self._desc_table, fieldInfo.name);
        const is_oneof = @as(std.meta.Tag(@TypeOf(descriptor.ftype)), descriptor.ftype) == .oneof;

        const field_present = switch (@typeInfo(fieldInfo.type)) {
            .optional => @field(self, fieldInfo.name) != null,
            else => if (opts.emit_default_values) true else blk: {
                break :blk !isDefaultValue(
                    @field(self, fieldInfo.name),
                    descriptor,
                );
            },
        };

        if (field_present) {
            // For oneof fields in flat mode, skip writing the container field name.
            // The variant name will be written directly into the parent object by
            // stringify_struct_field_with_options.
            if (!is_oneof or opts.emit_oneof_field_name) {
                try jws.objectField(camel_case_name);
            }
            try stringify_struct_field_with_options(
                @field(self, fieldInfo.name),
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
    comptime var capitalize_next_letter = false;
    comptime var camel_cased_string: []const u8 = "";
    comptime var i: usize = 0;

    inline for (not_camel_cased_string) |char| {
        if (char == '_') {
            capitalize_next_letter = i > 0;
        } else if (capitalize_next_letter) {
            camel_cased_string = camel_cased_string ++ .{
                comptime std.ascii.toUpper(char),
            };
            capitalize_next_letter = false;
            i += 1;
        } else {
            camel_cased_string = camel_cased_string ++ .{char};
            i += 1;
        }
    }

    // Build a new string with lowercase first letter instead of mutating const
    if (comptime std.ascii.isUpper(camel_cased_string[0])) {
        const lower_first = .{std.ascii.toLower(camel_cased_string[0])};
        camel_cased_string = lower_first ++ camel_cased_string[1..];
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

/// Parse a JSON object key into a protobuf map key type.
/// JSON object keys are always strings, so non-string key types
/// (integers, bools) are parsed from their string representation.
/// Handles both optional and non-optional key types (proto2 vs proto3).
fn parseMapKey(
    comptime KeyType: type,
    comptime key_desc: protobuf.FieldDescriptor,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !KeyType {
    // Unwrap optional layer if present (proto2 map entries may have optional fields)
    const InnerKeyType = switch (@typeInfo(KeyType)) {
        .optional => |opt| opt.child,
        else => KeyType,
    };

    const key_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    const key_str = switch (key_token) {
        inline .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };

    switch (comptime key_desc.ftype) {
        .scalar => |scalar| switch (scalar) {
            .string => {
                // For string keys: if allocated, take ownership; if slice into source, dupe
                return switch (key_token) {
                    .allocated_string => |s| s,
                    .string => |s| try allocator.dupe(u8, s),
                    else => unreachable,
                };
            },
            .bool => {
                defer freeAllocated(allocator, key_token);
                if (std.mem.eql(u8, key_str, "true")) return true;
                if (std.mem.eql(u8, key_str, "false")) return false;
                return error.UnexpectedToken;
            },
            else => {
                // Integer types: parse from decimal string, using the inner (non-optional) type
                defer freeAllocated(allocator, key_token);
                return std.fmt.parseInt(InnerKeyType, key_str, 10) catch return error.Overflow;
            },
        },
        else => unreachable, // Map keys can only be scalars
    }
}

/// Parse a JSON value into a protobuf map value type.
fn parseMapValue(
    comptime ValueType: type,
    comptime value_desc: protobuf.FieldDescriptor,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !ValueType {
    return switch (comptime value_desc.ftype) {
        .scalar => |scalar| switch (scalar) {
            .bytes => try parse_bytes(allocator, source, options),
            else => try std.json.innerParse(ValueType, allocator, source, options),
        },
        .submessage, .@"enum" => try std.json.innerParse(ValueType, allocator, source, options),
        else => unreachable, // map values can't be repeated/oneof
    };
}

/// Write a protobuf map key as a JSON object field name.
/// All JSON object keys must be strings, so non-string key types
/// (integers, bools) are formatted as their string representation.
/// Handles both optional and non-optional key types (proto2 vs proto3).
fn writeMapKey(raw_key: anytype, comptime key_desc: protobuf.FieldDescriptor, jws: anytype) !bool {
    // Unwrap optional keys (proto2 map entries may have optional fields)
    const key = switch (@typeInfo(@TypeOf(raw_key))) {
        .optional => raw_key orelse return false,
        else => raw_key,
    };
    switch (comptime key_desc.ftype) {
        .scalar => |scalar| switch (scalar) {
            .string => try jws.objectField(key),
            .bool => try jws.objectField(if (key) "true" else "false"),
            else => {
                // Integer types: format as decimal string for JSON object key
                // i64 min "-9223372036854775808" and u64 max "18446744073709551615" are both exactly 20 chars
                var buf: [20]u8 = undefined;
                const key_str = std.fmt.bufPrint(&buf, "{d}", .{key}) catch unreachable;
                try jws.objectField(key_str);
            },
        },
        else => unreachable, // Map keys can only be scalars (no floats, bytes, enum, message)
    }
    return true;
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
        .@"enum" => {
            // NullValue enum serializes as JSON null per proto3 spec
            const ValueType = @TypeOf(value);
            const is_null_value = comptime @hasField(ValueType, "NULL_VALUE");
            if (is_null_value) {
                try jws.write(null);
            } else {
                try print_numeric(value, jws);
            }
        },
        .repeated, .packed_repeated => |repeated| {
            const slice = value.items;
            // Detect map entry types at comptime: submessage with _is_map_entry marker
            const ElType = @typeInfo(@TypeOf(slice)).pointer.child;
            const is_map = comptime blk: {
                if (@as(std.meta.Tag(@TypeOf(repeated)), repeated) != .submessage) break :blk false;
                break :blk @hasDecl(ElType, "_is_map_entry") and ElType._is_map_entry;
            };

            if (is_map) {
                // Protobuf JSON spec: maps serialize as JSON objects
                try jws.beginObject();
                for (slice) |el| {
                    if (try writeMapKey(el.key, @field(ElType._desc_table, "key"), jws)) {
                        const val_null = if (comptime @typeInfo(@TypeOf(el.value)) == .optional) el.value == null else false;
                        if (val_null) {
                            try jws.beginObject();
                            try jws.endObject();
                        } else {
                            try stringify_struct_field_with_options(el.value, @field(ElType._desc_table, "value"), jws, pb_options);
                        }
                    }
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
                        .@"enum" => {
                            // NullValue enum serializes as JSON null per proto3 spec
                            const is_null_value = comptime @hasField(union_field.type, "NULL_VALUE");
                            if (is_null_value) {
                                try jws.write(null);
                            } else {
                                try print_numeric(@field(value, union_field.name), jws);
                            }
                        },
                        .submessage => try stringifyOpts(union_field.type, &@field(value, union_field.name), jws, pb_options),
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
            try stringifyOpts(@TypeOf(value), &value, jws, pb_options);
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
            // Detect map entry types at comptime: submessage with _is_map_entry marker
            const ElType = @typeInfo(@TypeOf(slice)).pointer.child;
            const is_map = comptime blk: {
                if (@as(std.meta.Tag(@TypeOf(repeated)), repeated) != .submessage) break :blk false;
                break :blk @hasDecl(ElType, "_is_map_entry") and ElType._is_map_entry;
            };

            if (is_map) {
                // Protobuf JSON spec: maps serialize as JSON objects
                try jws.beginObject();
                for (slice) |el| {
                    if (try writeMapKey(el.key, @field(ElType._desc_table, "key"), jws)) {
                        const val_null = if (comptime @typeInfo(@TypeOf(el.value)) == .optional) el.value == null else false;
                        if (val_null) {
                            try jws.beginObject();
                            try jws.endObject();
                        } else {
                            const value_desc = @field(ElType._desc_table, "value");
                            switch (comptime value_desc.ftype) {
                                .scalar => |scalar| switch (scalar) {
                                    .bytes => try print_bytes(el.value, jws),
                                    .string => try jws.write(el.value),
                                    else => try print_numeric(el.value, jws),
                                },
                                .@"enum" => try print_numeric(el.value, jws),
                                .submessage => try jws.write(el.value),
                                else => unreachable, // map values can't be repeated/oneof
                            }
                        }
                    }
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
                        .submessage => try jws.write(el),
                    }
                }
                try jws.endArray();
            }
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

fn parseStructField(
    comptime T: type,
    result: *T,
    comptime fieldInfo: std.builtin.Type.StructField,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !void {
    const field_desc = @field(T._desc_table, fieldInfo.name);

    // Handle JSON null for all field types per proto3 spec.
    // - Optional fields → set to null
    // - Scalar/enum fields → set to default value
    // - Repeated fields → error (null not allowed for arrays)
    // - google.protobuf.Value fields → Value{.kind = .{.null_value = .NULL_VALUE}}
    // - google.protobuf.NullValue enum → .NULL_VALUE
    // - Oneof fields → set to null (clear the oneof)
    if (.null == try source.peekNextTokenType()) {
        _ = try source.next(); // consume the null token

        const is_value_wkt = comptime blk: {
            const InnerType = switch (@typeInfo(fieldInfo.type)) {
                .optional => |opt| opt.child,
                else => fieldInfo.type,
            };
            if (@typeInfo(InnerType) != .@"struct") break :blk false;
            break :blk @hasDecl(InnerType, "_well_known_type") and
                InnerType._well_known_type == .value;
        };

        const is_null_value_enum = comptime blk: {
            const InnerType = switch (@typeInfo(fieldInfo.type)) {
                .optional => |opt| opt.child,
                else => fieldInfo.type,
            };
            if (@typeInfo(InnerType) != .@"enum") break :blk false;
            break :blk @hasField(InnerType, "NULL_VALUE");
        };

        if (is_value_wkt) {
            // google.protobuf.Value: null maps to Value{kind = {null_value: NULL_VALUE}}
            const InnerType = switch (@typeInfo(fieldInfo.type)) {
                .optional => |opt| opt.child,
                else => fieldInfo.type,
            };
            const KindFieldType = @TypeOf(@as(InnerType, undefined).kind);
            const KindUnion = @typeInfo(KindFieldType).optional.child;
            @field(result.*, fieldInfo.name) = InnerType{
                .kind = @unionInit(KindUnion, "null_value", .NULL_VALUE),
            };
        } else if (is_null_value_enum) {
            // google.protobuf.NullValue: null maps to NULL_VALUE
            const InnerType = switch (@typeInfo(fieldInfo.type)) {
                .optional => |opt| opt.child,
                else => fieldInfo.type,
            };
            @field(result.*, fieldInfo.name) = @field(InnerType, "NULL_VALUE");
        } else {
            // For optional types, set to null; for non-optional, set to default
            if (@typeInfo(fieldInfo.type) == .optional) {
                @field(result.*, fieldInfo.name) = null;
            } else if (fieldInfo.defaultValue()) |default| {
                @field(result.*, fieldInfo.name) = default;
            } else {
                return error.UnexpectedToken;
            }
        }
        return;
    }

    @field(result.*, fieldInfo.name) = switch (field_desc.ftype) {
        .repeated, .packed_repeated => |repeated| list: {
            // repeated T -> ArrayListUnmanaged(T)
            const child_type = @typeInfo(
                fieldInfo.type.Slice,
            ).pointer.child;

            // Detect map entry types at comptime
            const is_map = comptime blk: {
                if (@as(std.meta.Tag(@TypeOf(repeated)), repeated) != .submessage) break :blk false;
                break :blk @hasDecl(child_type, "_is_map_entry") and child_type._is_map_entry;
            };

            if (is_map) {
                // Protobuf JSON spec: maps are JSON objects
                switch (try source.peekNextTokenType()) {
                    .object_begin => {
                        std.debug.assert(.object_begin == try source.next());
                        var array_list: std.ArrayList(child_type) = .empty;
                        while (true) {
                            if (.object_end == try source.peekNextTokenType()) {
                                _ = try source.next();
                                break;
                            }
                            try array_list.ensureUnusedCapacity(allocator, 1);
                            var entry: child_type = undefined;
                            entry.key = try parseMapKey(
                                @TypeOf(entry.key),
                                @field(child_type._desc_table, "key"),
                                allocator,
                                source,
                                options,
                            );
                            // Free string key allocation if value parsing fails
                            const key_ftype = comptime @field(child_type._desc_table, "key").ftype;
                            const key_is_string = comptime (key_ftype == .scalar and key_ftype.scalar == .string);
                            errdefer if (key_is_string) {
                                if (@typeInfo(@TypeOf(entry.key)) == .optional) {
                                    if (entry.key) |k| allocator.free(k);
                                } else {
                                    allocator.free(entry.key);
                                }
                            };
                            entry.value = try parseMapValue(
                                @TypeOf(entry.value),
                                @field(child_type._desc_table, "value"),
                                allocator,
                                source,
                                options,
                            );
                            array_list.appendAssumeCapacity(entry);
                        }
                        break :list array_list;
                    },
                    else => return error.UnexpectedToken,
                }
            } else {
                switch (try source.peekNextTokenType()) {
                    .array_begin => {
                        std.debug.assert(.array_begin == try source.next());
                        var array_list: std.ArrayList(child_type) = .empty;
                        while (true) {
                            if (.array_end == try source.peekNextTokenType()) {
                                _ = try source.next();
                                break;
                            }
                            try array_list.ensureUnusedCapacity(allocator, 1);
                            array_list.appendAssumeCapacity(switch (repeated) {
                                .scalar => |scalar| switch (scalar) {
                                    .bytes => try parse_bytes(allocator, source, options),
                                    else => try std.json.innerParse(
                                        child_type,
                                        allocator,
                                        source,
                                        options,
                                    ),
                                },
                                .submessage, .@"enum" => other: {
                                    break :other try std.json.innerParse(
                                        child_type,
                                        allocator,
                                        source,
                                        options,
                                    );
                                },
                            });
                        }
                        break :list array_list;
                    },
                    else => return error.UnexpectedToken,
                }
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
                            .submessage, .@"enum" => other: {
                                break :other try std.json.innerParse(
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
        // `.submessage`s (generated structs) have their own jsonParse implementation
        .@"enum", .submessage => try std.json.innerParse(
            fieldInfo.type,
            allocator,
            source,
            options,
        ),
        .scalar => |scalar| switch (scalar) {
            .bytes => try parse_bytes(allocator, source, options),
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

// ---------------------------------------------------------------------------
// Well-Known Type JSON encoding/decoding
// ---------------------------------------------------------------------------
// Per the proto3 JSON mapping spec, certain google.protobuf types have special
// JSON representations that differ from their normal message encoding.
// All dispatch is comptime — zero runtime cost for non-WKT types.

fn stringifyWellKnownType(Self: type, self: *const Self, jws: anytype, opts: Options) !void {
    _ = opts;
    switch (comptime Self._well_known_type) {
        .double_value, .float_value => try print_numeric(self.value, jws),
        .int32_value, .uint32_value => try jws.write(self.value),
        .int64_value, .uint64_value => {
            // Proto JSON spec: 64-bit integers must be quoted strings
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
            try jws.write(s);
        },
        .bool_value => try jws.write(self.value),
        .string_value => try jws.write(self.value),
        .bytes_value => try print_bytes(self.value, jws),
        .timestamp => try stringifyTimestamp(self, jws),
        .duration => try stringifyDuration(self, jws),
        .value => try stringifyGoogleValue(self.kind, jws),
        .@"struct" => {
            // Struct: unwrap to JSON object with Value entries
            try jws.beginObject();
            for (self.fields.items) |entry| {
                try jws.objectField(entry.key);
                if (entry.value) |val| {
                    try stringifyGoogleValue(val.kind, jws);
                } else {
                    try jws.write(null);
                }
            }
            try jws.endObject();
        },
        .list_value => {
            // ListValue: unwrap to JSON array of Values
            try jws.beginArray();
            for (self.values.items) |val| {
                try stringifyGoogleValue(val.kind, jws);
            }
            try jws.endArray();
        },
        .field_mask => try stringifyFieldMask(self, jws),
    }
}

/// Unified Value/Struct/ListValue serializer.
/// Takes the optional kind_union directly to avoid mutual function recursion
/// which would create a dependency loop on inferred error sets.
fn stringifyGoogleValue(kind_opt: anytype, jws: anytype) !void {
    const kind = kind_opt orelse {
        try jws.write(null);
        return;
    };

    const KindUnion = @TypeOf(kind);
    const tag = @as(std.meta.Tag(KindUnion), kind);

    switch (tag) {
        .null_value => try jws.write(null),
        .number_value => {
            // Proto3 spec: NaN and Infinity are not representable in JSON
            // for google.protobuf.Value. Reject them.
            if (std.math.isNan(kind.number_value) or std.math.isInf(kind.number_value))
                return error.RangeError;
            try print_numeric(kind.number_value, jws);
        },
        .string_value => try jws.write(kind.string_value),
        .bool_value => try jws.write(kind.bool_value),
        .struct_value => {
            try jws.beginObject();
            for (kind.struct_value.fields.items) |entry| {
                try jws.objectField(entry.key);
                if (entry.value) |val| {
                    try stringifyGoogleValue(val.kind, jws);
                } else {
                    try jws.write(null);
                }
            }
            try jws.endObject();
        },
        .list_value => {
            try jws.beginArray();
            for (kind.list_value.values.items) |val| {
                try stringifyGoogleValue(val.kind, jws);
            }
            try jws.endArray();
        },
    }
}

fn parseWellKnownType(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    switch (comptime Self._well_known_type) {
        .double_value, .float_value, .int32_value, .uint32_value,
        .bool_value, .string_value,
        => {
            return Self{ .value = try std.json.innerParse(
                @TypeOf(@as(Self, undefined).value),
                allocator,
                source,
                options,
            ) };
        },
        .int64_value, .uint64_value => {
            const ValueType = @TypeOf(@as(Self, undefined).value);
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            switch (token) {
                inline .string, .allocated_string => |s| {
                    defer freeAllocated(allocator, token);
                    return Self{ .value = std.fmt.parseInt(ValueType, s, 10) catch return error.UnexpectedToken };
                },
                inline .number, .allocated_number => |n| {
                    defer freeAllocated(allocator, token);
                    return Self{ .value = std.fmt.parseInt(ValueType, n, 10) catch return error.UnexpectedToken };
                },
                else => return error.UnexpectedToken,
            }
        },
        .bytes_value => {
            return Self{ .value = try parse_bytes(allocator, source, options) };
        },
        .timestamp => return parseTimestamp(Self, allocator, source, options),
        .duration => return parseDuration(Self, allocator, source, options),
        .value => return Self{ .kind = try parseGoogleValue(Self, allocator, source, options) },
        .@"struct" => return parseGoogleStruct(Self, allocator, source, options),
        .list_value => return parseGoogleListValue(Self, allocator, source, options),
        .field_mask => return parseFieldMask(Self, allocator, source, options),
    }
}

// -- Timestamp --

fn stringifyTimestamp(self: anytype, jws: anytype) !void {
    const secs = self.seconds;
    const nanos = self.nanos;

    // Validate range per proto3 spec:
    // seconds: [-62135596800, 253402300799] (0001-01-01T00:00:00Z to 9999-12-31T23:59:59Z)
    // nanos: [0, 999999999] (always non-negative for timestamps)
    if (secs < -62135596800 or secs > 253402300799) return error.RangeError;
    if (nanos < 0 or nanos > 999999999) return error.RangeError;

    // Convert Unix epoch seconds to civil date/time components
    // Valid range: 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z
    const epoch = epochToDateTime(secs);

    try jsonValueStartAssumeTypeOk(jws);
    try jws.writer.writeByte('"');

    // YYYY-MM-DDThh:mm:ss
    var buf: [32]u8 = undefined;
    const date_len = (std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        epoch.year, epoch.month, epoch.day, epoch.hour, epoch.minute, epoch.second,
    }) catch unreachable).len;
    try jws.writer.writeAll(buf[0..date_len]);

    // Fractional seconds: use 0, 3, 6, or 9 digits, trimming trailing zeros
    if (nanos != 0) {
        const abs_nanos: u32 = if (nanos < 0) @intCast(-@as(i32, nanos)) else @intCast(nanos);
        if (abs_nanos % 1_000_000 == 0) {
            // 3 digits
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>3}", .{abs_nanos / 1_000_000}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        } else if (abs_nanos % 1_000 == 0) {
            // 6 digits
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>6}", .{abs_nanos / 1_000}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        } else {
            // 9 digits
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>9}", .{abs_nanos}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        }
    }

    try jws.writer.writeByte('Z');
    try jws.writer.writeByte('"');
    jws.next_punctuation = .comma;
}

const DateTime = struct {
    year: u32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
};

fn epochToDateTime(epoch_seconds: i64) DateTime {
    // Algorithm: convert Unix epoch seconds to civil date.
    // Days since Unix epoch (floor division for negative values)
    const secs_per_day: i64 = 86400;
    var day_offset: i64 = @divFloor(epoch_seconds, secs_per_day);
    const time_of_day: i64 = @mod(epoch_seconds, secs_per_day);

    // Shift epoch from 1970-01-01 to 0000-03-01 for easier leap year handling
    // 719468 days from 0000-03-01 to 1970-01-01
    day_offset += 719468;

    // Civil date from day count (Rata Die algorithm variant)
    const era: i64 = @divFloor(if (day_offset >= 0) day_offset else day_offset - 146096, 146097);
    const doe: u32 = @intCast(day_offset - era * 146097); // day of era [0, 146096]
    const yoe: u32 = @intCast((@as(u64, doe) -| doe / 1460 + doe / 36524 -| doe / 146096) / 365); // year of era [0, 399]
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 -| yoe / 100); // day of year [0, 365]
    const mp: u32 = (5 * doy + 2) / 153; // month from March [0, 11]
    const d: u32 = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // month [1, 12]
    const adjusted_y: u32 = @intCast(y + @as(i64, if (m <= 2) @as(i64, 1) else @as(i64, 0)));

    // Time of day from remainder
    const sod: u32 = @intCast(time_of_day);
    return .{
        .year = adjusted_y,
        .month = m,
        .day = d,
        .hour = sod / 3600,
        .minute = (sod % 3600) / 60,
        .second = sod % 60,
    };
}

fn parseTimestamp(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    const str = switch (token) {
        inline .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };
    defer freeAllocated(allocator, token);

    // Parse RFC 3339: YYYY-MM-DDThh:mm:ss[.fractional](Z|+HH:MM|-HH:MM)
    if (str.len < 20) return error.UnexpectedToken; // minimum: "YYYY-MM-DDThh:mm:ssZ"
    if (str[4] != '-' or str[7] != '-' or str[10] != 'T' or str[13] != ':' or str[16] != ':')
        return error.UnexpectedToken;

    const year = std.fmt.parseInt(u32, str[0..4], 10) catch return error.UnexpectedToken;
    const month = std.fmt.parseInt(u32, str[5..7], 10) catch return error.UnexpectedToken;
    const day = std.fmt.parseInt(u32, str[8..10], 10) catch return error.UnexpectedToken;
    const hour = std.fmt.parseInt(u32, str[11..13], 10) catch return error.UnexpectedToken;
    const minute = std.fmt.parseInt(u32, str[14..16], 10) catch return error.UnexpectedToken;
    const second = std.fmt.parseInt(u32, str[17..19], 10) catch return error.UnexpectedToken;

    // Find where the timezone designator starts (after seconds and optional fractional part)
    // Possible formats after seconds: Z, +HH:MM, -HH:MM
    // Fractional seconds come before the timezone designator
    var tz_start: usize = 19;
    var nanos: i32 = 0;

    if (tz_start < str.len and str[tz_start] == '.') {
        // Find end of fractional part (next 'Z', '+', or '-')
        var frac_end: usize = tz_start + 1;
        while (frac_end < str.len) : (frac_end += 1) {
            if (str[frac_end] == 'Z' or str[frac_end] == '+' or str[frac_end] == '-') break;
        }
        if (frac_end >= str.len) return error.UnexpectedToken;

        const frac_str = str[tz_start + 1 .. frac_end];
        if (frac_str.len == 0 or frac_str.len > 9) return error.UnexpectedToken;
        var frac_val = std.fmt.parseInt(u32, frac_str, 10) catch return error.UnexpectedToken;
        // Pad to 9 digits
        var digits: u32 = @intCast(frac_str.len);
        while (digits < 9) : (digits += 1) {
            frac_val *= 10;
        }
        nanos = @intCast(frac_val);
        tz_start = frac_end;
    }

    // Parse timezone offset
    var offset_seconds: i64 = 0;
    if (tz_start >= str.len) return error.UnexpectedToken;

    if (str[tz_start] == 'Z') {
        // UTC, no offset
        if (tz_start + 1 != str.len) return error.UnexpectedToken;
    } else if (str[tz_start] == '+' or str[tz_start] == '-') {
        // Parse +HH:MM or -HH:MM
        const tz_str = str[tz_start..];
        if (tz_str.len != 6 or tz_str[3] != ':') return error.UnexpectedToken;
        const tz_hours = std.fmt.parseInt(u32, tz_str[1..3], 10) catch return error.UnexpectedToken;
        const tz_minutes = std.fmt.parseInt(u32, tz_str[4..6], 10) catch return error.UnexpectedToken;
        offset_seconds = @as(i64, tz_hours) * 3600 + @as(i64, tz_minutes) * 60;
        if (str[tz_start] == '+') {
            offset_seconds = -offset_seconds; // positive offset means ahead of UTC, subtract to get UTC
        }
    } else {
        return error.UnexpectedToken;
    }

    // Convert civil date to Unix epoch seconds, then apply timezone offset
    const epoch_seconds = dateTimeToEpoch(year, month, day, hour, minute, second) + offset_seconds;

    // Validate range per proto3 spec
    if (epoch_seconds < -62135596800 or epoch_seconds > 253402300799) return error.UnexpectedToken;

    return Self{ .seconds = epoch_seconds, .nanos = nanos };
}

fn dateTimeToEpoch(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) i64 {
    // Inverse of epochToDateTime: civil date to Unix epoch seconds
    const y: i64 = @as(i64, @intCast(year)) - @as(i64, if (month <= 2) 1 else 0);
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400); // year of era [0, 399]
    const m_adjusted: u32 = if (month > 2) month - 3 else month + 9; // month from March [0, 11]
    const doy: u32 = (153 * m_adjusted + 2) / 5 + day - 1; // day of year [0, 365]
    const doe: u32 = yoe * 365 + yoe / 4 -| yoe / 100 + doy; // day of era [0, 146096]
    const day_offset: i64 = era * 146097 + @as(i64, doe) - 719468; // days since Unix epoch

    return day_offset * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

// -- Duration --

fn stringifyDuration(self: anytype, jws: anytype) !void {
    const secs = self.seconds;
    const nanos = self.nanos;

    // Validate range per proto3 spec:
    // seconds: [-315576000000, 315576000000] (±10000 years)
    // nanos: [-999999999, 999999999]
    // seconds and nanos must have the same sign (or nanos must be 0)
    if (secs < -315576000000 or secs > 315576000000) return error.RangeError;
    if (nanos < -999999999 or nanos > 999999999) return error.RangeError;
    if (secs > 0 and nanos < 0) return error.RangeError;
    if (secs < 0 and nanos > 0) return error.RangeError;

    try jsonValueStartAssumeTypeOk(jws);
    try jws.writer.writeByte('"');

    // Handle sign: seconds and nanos should have the same sign
    const negative = secs < 0 or nanos < 0;
    if (negative) try jws.writer.writeByte('-');

    const abs_secs: u64 = if (secs < 0) @intCast(-secs) else @intCast(secs);
    const abs_nanos: u32 = if (nanos < 0) @intCast(-@as(i32, nanos)) else @intCast(nanos);

    var buf: [32]u8 = undefined;
    const secs_str = std.fmt.bufPrint(&buf, "{d}", .{abs_secs}) catch unreachable;
    try jws.writer.writeAll(secs_str);

    if (abs_nanos != 0) {
        if (abs_nanos % 1_000_000 == 0) {
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>3}", .{abs_nanos / 1_000_000}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        } else if (abs_nanos % 1_000 == 0) {
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>6}", .{abs_nanos / 1_000}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        } else {
            const frac_buf = std.fmt.bufPrint(&buf, ".{d:0>9}", .{abs_nanos}) catch unreachable;
            try jws.writer.writeAll(frac_buf);
        }
    }

    try jws.writer.writeByte('s');
    try jws.writer.writeByte('"');
    jws.next_punctuation = .comma;
}

fn parseDuration(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    const str = switch (token) {
        inline .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };
    defer freeAllocated(allocator, token);

    if (str.len < 2) return error.UnexpectedToken; // minimum: "0s"
    if (str[str.len - 1] != 's') return error.UnexpectedToken;

    const body = str[0 .. str.len - 1]; // strip trailing 's'
    const negative = body.len > 0 and body[0] == '-';
    const unsigned_body = if (negative) body[1..] else body;

    // Split on '.'
    var seconds: i64 = 0;
    var nanos: i32 = 0;

    if (std.mem.indexOfScalar(u8, unsigned_body, '.')) |dot_idx| {
        seconds = std.fmt.parseInt(i64, unsigned_body[0..dot_idx], 10) catch return error.UnexpectedToken;
        const frac_str = unsigned_body[dot_idx + 1 ..];
        if (frac_str.len == 0 or frac_str.len > 9) return error.UnexpectedToken;
        var frac_val = std.fmt.parseInt(u32, frac_str, 10) catch return error.UnexpectedToken;
        var digits: u32 = @intCast(frac_str.len);
        while (digits < 9) : (digits += 1) {
            frac_val *= 10;
        }
        nanos = @intCast(frac_val);
    } else {
        seconds = std.fmt.parseInt(i64, unsigned_body, 10) catch return error.UnexpectedToken;
    }

    if (negative) {
        seconds = -seconds;
        nanos = -nanos;
    }

    // Validate range per proto3 spec
    if (seconds < -315576000000 or seconds > 315576000000) return error.UnexpectedToken;

    return Self{ .seconds = seconds, .nanos = nanos };
}

// -- Value / Struct / ListValue --
// These three types are mutually recursive. To avoid dependency loops on
// inferred error sets in Zig's comptime, all parse logic is unified into
// a single recursive function (parseGoogleValue) that handles struct objects
// and list arrays inline. Top-level parsers (for Struct and ListValue) are
// thin wrappers that consume the opening token and delegate.

/// Parse a google.protobuf.Value kind from the JSON token stream.
/// This is the single recursive function for the Value/Struct/ListValue triad.
/// It peeks at the next token type and dispatches accordingly. For object_begin
/// and array_begin, it parses the contents inline to avoid cross-function
/// error-set dependency loops.
fn parseGoogleValue(
    ValueSelf: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !@TypeOf(@as(ValueSelf, undefined).kind) {
    const KindFieldType = @TypeOf(@as(ValueSelf, undefined).kind);
    const KindUnion = @typeInfo(KindFieldType).optional.child;

    const peeked = try source.peekNextTokenType();
    switch (peeked) {
        .null => {
            _ = try source.next();
            return @unionInit(KindUnion, "null_value", .NULL_VALUE);
        },
        .true, .false => {
            const tok = try source.next();
            return @unionInit(KindUnion, "bool_value", tok == .true);
        },
        .number => {
            const num = try std.json.innerParse(f64, allocator, source, options);
            return @unionInit(KindUnion, "number_value", num);
        },
        .string => {
            const s = try std.json.innerParse([]const u8, allocator, source, options);
            // Per proto3 JSON spec, NaN/Infinity are encoded as strings
            if (std.mem.eql(u8, s, "NaN")) {
                return @unionInit(KindUnion, "number_value", std.math.nan(f64));
            } else if (std.mem.eql(u8, s, "Infinity")) {
                return @unionInit(KindUnion, "number_value", std.math.inf(f64));
            } else if (std.mem.eql(u8, s, "-Infinity")) {
                return @unionInit(KindUnion, "number_value", -std.math.inf(f64));
            }
            return @unionInit(KindUnion, "string_value", s);
        },
        .object_begin => {
            // Inline struct parsing to avoid cross-function error set loop
            _ = try source.next(); // consume object_begin
            const StructType = @TypeOf(@as(KindUnion, undefined).struct_value);
            const EntryType = @typeInfo(@TypeOf(@as(StructType, undefined).fields.items)).pointer.child;
            const InnerValueType = blk: {
                const VT = @TypeOf(@as(EntryType, undefined).value);
                break :blk switch (@typeInfo(VT)) {
                    .optional => |opt| opt.child,
                    else => VT,
                };
            };
            var entries: std.ArrayList(EntryType) = .empty;
            while (true) {
                if (.object_end == try source.peekNextTokenType()) {
                    _ = try source.next();
                    break;
                }
                const key_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const key = switch (key_token) {
                    .allocated_string => |s| s,
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.UnexpectedToken,
                };
                errdefer allocator.free(key);
                const kind = try parseGoogleValue(InnerValueType, allocator, source, options);
                try entries.append(allocator, .{
                    .key = key,
                    .value = InnerValueType{ .kind = kind },
                });
            }
            return @unionInit(KindUnion, "struct_value", StructType{ .fields = entries });
        },
        .array_begin => {
            // Inline list parsing to avoid cross-function error set loop
            _ = try source.next(); // consume array_begin
            const ListType = @TypeOf(@as(KindUnion, undefined).list_value);
            const ElemType = @typeInfo(@TypeOf(@as(ListType, undefined).values.items)).pointer.child;
            var values: std.ArrayList(ElemType) = .empty;
            while (true) {
                if (.array_end == try source.peekNextTokenType()) {
                    _ = try source.next();
                    break;
                }
                const kind = try parseGoogleValue(ElemType, allocator, source, options);
                try values.append(allocator, ElemType{ .kind = kind });
            }
            return @unionInit(KindUnion, "list_value", ListType{ .values = values });
        },
        else => return error.UnexpectedToken,
    }
}

/// Parse a top-level google.protobuf.Struct from a JSON object.
fn parseGoogleStruct(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    if (.object_begin != try source.next()) return error.UnexpectedToken;

    const EntryType = @typeInfo(@TypeOf(@as(Self, undefined).fields.items)).pointer.child;
    const InnerValueType = blk: {
        const VT = @TypeOf(@as(EntryType, undefined).value);
        break :blk switch (@typeInfo(VT)) {
            .optional => |opt| opt.child,
            else => VT,
        };
    };

    var entries: std.ArrayList(EntryType) = .empty;

    while (true) {
        if (.object_end == try source.peekNextTokenType()) {
            _ = try source.next();
            break;
        }
        const key_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const key = switch (key_token) {
            .allocated_string => |s| s,
            .string => |s| try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        };
        errdefer allocator.free(key);

        const kind = try parseGoogleValue(InnerValueType, allocator, source, options);
        try entries.append(allocator, .{
            .key = key,
            .value = InnerValueType{ .kind = kind },
        });
    }

    return Self{ .fields = entries };
}

/// Parse a top-level google.protobuf.ListValue from a JSON array.
fn parseGoogleListValue(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    if (.array_begin != try source.next()) return error.UnexpectedToken;

    const ValueType = @typeInfo(@TypeOf(@as(Self, undefined).values.items)).pointer.child;
    var values: std.ArrayList(ValueType) = .empty;

    while (true) {
        if (.array_end == try source.peekNextTokenType()) {
            _ = try source.next();
            break;
        }
        const kind = try parseGoogleValue(ValueType, allocator, source, options);
        try values.append(allocator, ValueType{ .kind = kind });
    }

    return Self{ .values = values };
}

// -- FieldMask --

fn stringifyFieldMask(self: anytype, jws: anytype) !void {
    // FieldMask JSON: paths joined with commas, each segment snake_case → camelCase
    // Per proto3 spec: paths that don't round-trip through snake_case↔camelCase
    // conversion must fail to serialize.
    //
    // Validate round-trip before writing anything:
    for (self.paths.items) |path| {
        if (!fieldMaskPathRoundTrips(path)) return error.RangeError;
    }

    try jsonValueStartAssumeTypeOk(jws);
    try jws.writer.writeByte('"');

    for (self.paths.items, 0..) |path, i| {
        if (i > 0) try jws.writer.writeByte(',');
        // Convert each path segment to camelCase at runtime
        try writeSnakeToCamel(jws.writer, path);
    }

    try jws.writer.writeByte('"');
    jws.next_punctuation = .comma;
}

/// Check if a snake_case path round-trips through snake→camel→snake conversion.
/// Returns false if the path contains patterns that break the round-trip:
/// - Multiple consecutive underscores (e.g., "foo__bar")
/// - Trailing underscore
/// - Uppercase letters (not valid snake_case)
/// - Numeric characters after underscores (e.g., "foo_3_bar")
fn fieldMaskPathRoundTrips(path: []const u8) bool {
    if (path.len == 0) return true;

    // Check for invalid patterns in the original snake_case path
    var prev_underscore = false;
    for (path, 0..) |c, i| {
        if (c == '_') {
            if (prev_underscore) return false; // consecutive underscores
            if (i == path.len - 1) return false; // trailing underscore
            prev_underscore = true;
        } else {
            if (std.ascii.isUpper(c)) return false; // uppercase not valid snake_case
            if (prev_underscore and std.ascii.isDigit(c)) return false; // digit after underscore
            prev_underscore = false;
        }
    }
    return true;
}

fn writeSnakeToCamel(writer: anytype, snake: []const u8) !void {
    var capitalize_next = false;
    for (snake) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else if (capitalize_next) {
            try writer.writeByte(std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try writer.writeByte(c);
        }
    }
}

fn parseFieldMask(
    Self: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Self {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    const str = switch (token) {
        inline .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };
    defer freeAllocated(allocator, token);

    var paths: std.ArrayList([]const u8) = .empty;

    if (str.len == 0) {
        return Self{ .paths = paths };
    }

    // Split on commas, convert each segment from camelCase to snake_case
    var start: usize = 0;
    for (str, 0..) |c, i| {
        if (c == ',') {
            const snake = try camelToSnake(allocator, str[start..i]);
            try paths.append(allocator, snake);
            start = i + 1;
        }
    }
    // Last segment
    const snake = try camelToSnake(allocator, str[start..]);
    try paths.append(allocator, snake);

    return Self{ .paths = paths };
}

fn camelToSnake(allocator: std.mem.Allocator, camel: []const u8) ![]const u8 {
    // Count how many underscores we need to insert
    var extra: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) extra += 1;
    }

    const result = try allocator.alloc(u8, camel.len + extra);
    var j: usize = 0;
    for (camel) |c| {
        if (std.ascii.isUpper(c)) {
            result[j] = '_';
            j += 1;
            result[j] = std.ascii.toLower(c);
            j += 1;
        } else {
            result[j] = c;
            j += 1;
        }
    }
    return result[0..j];
}

fn print_numeric(value: anytype, jws: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .float, .comptime_float => {},
        .int, .comptime_int => {
            // Proto JSON spec: 64-bit integers must be quoted strings
            if (@typeInfo(@TypeOf(value)) == .int and @bitSizeOf(@TypeOf(value)) == 64) {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                try jws.write(s);
            } else {
                try jws.write(value);
            }
            return;
        },
        .@"enum", .bool => {
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

fn parse_bytes(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) ![]const u8 {
    const temp_raw = try std.json.innerParse([]u8, allocator, source, options);
    const size = std.base64.standard.Decoder.calcSizeForSlice(temp_raw) catch |err| {
        return base64ErrorToJsonParseError(err);
    };
    const tempstring = try allocator.alloc(u8, size);
    errdefer allocator.free(tempstring);
    std.base64.standard.Decoder.decode(tempstring, temp_raw) catch |err| {
        return base64ErrorToJsonParseError(err);
    };
    return tempstring;
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
