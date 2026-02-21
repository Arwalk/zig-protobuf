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
    options: std.json.Stringify.Options,
    allocator: std.mem.Allocator,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, data, options);
}

pub fn stringify(Self: type, self: *const Self, jws: anytype) !void {
    return stringifyOpts(Self, self, jws, .{});
}

/// Encode a protobuf message to JSON with explicit options.
/// Use this when you need the standard protobuf JSON format (flat oneof fields).
///
/// Example:
///   var buf = std.ArrayList(u8).init(allocator);
///   defer buf.deinit();
///   var jws = std.json.writeStream(buf.writer(), .{});
///   try pb.json.stringifyWithOptions(MyMessage, &msg, &jws, .{ .emit_oneof_field_name = false });
pub fn stringifyWithOptions(
    Self: type,
    self: *const Self,
    jws: anytype,
    opts: Options,
) !void {
    return stringifyOpts(Self, self, jws, opts);
}

fn stringifyOpts(Self: type, self: *const Self, jws: anytype, opts: Options) !void {
    // Increase eval branch quota for types with hundreds of fields
    @setEvalBranchQuota(1000000);

    try jws.beginObject();

    inline for (@typeInfo(Self).@"struct".fields) |fieldInfo| {
        const camel_case_name = comptime to_camel_case(fieldInfo.name);
        const descriptor = @field(Self._desc_table, fieldInfo.name);
        const is_oneof = @as(std.meta.Tag(@TypeOf(descriptor.ftype)), descriptor.ftype) == .oneof;

        const field_present = switch (@typeInfo(fieldInfo.type)) {
            .optional => @field(self, fieldInfo.name) != null,
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

            if (pb_options.emit_oneof_field_name) {
                try jws.endObject();
            }
        },
        .submessage => {
            try jws.write(value);
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
            switch (try source.peekNextTokenType()) {
                .array_begin => {
                    std.debug.assert(.array_begin == try source.next());
                    const child_type = @typeInfo(
                        fieldInfo.type.Slice,
                    ).pointer.child;
                    var array_list: std.ArrayListUnmanaged(child_type) = .empty;
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

fn print_numeric(value: anytype, jws: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .float, .comptime_float => {},
        .int, .comptime_int, .@"enum", .bool => {
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
