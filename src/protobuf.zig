const std = @import("std");

const log = std.log.scoped(.zig_protobuf);

pub const json = @import("json.zig");
pub const wire = @import("wire.zig");

pub const DecodingError = error{ NotEnoughData, InvalidInput };

/// Main tagged union holding the details of any field type.
pub const FieldType = union(enum) {
    scalar: Scalar,
    @"enum": void,
    submessage: void,
    list: List,
    packed_list: List,
    oneof: type,

    pub fn toWire(comptime ftype: FieldType) wire.Type {
        return switch (comptime ftype) {
            .scalar => |s| s.toWire(),
            .submessage, .packed_list => .len,
            .list => |inner| switch (comptime inner) {
                .scalar => |s| s.toWire(),
                .@"enum" => .varint,
                .submessage => .len,
            },
            .@"enum" => .varint,
            .oneof => @compileError("Shouldn't pass a .oneof field to this function here."),
        };
    }

    pub const Tag = std.meta.Tag(FieldType);

    pub const Scalar =
        enum {
            /// Uses variable-length encoding. Inefficient for encoding negative
            /// numbers -- if your field is likely to have negative values, use
            /// `sint32` instead.
            int32,
            /// Uses variable-length encoding. Inefficient for encoding negative
            /// numbers -- if your field is likely to have negative values, use
            /// `sint64` instead.
            int64,
            /// Uses variable-length encoding.
            uint32,
            /// Uses variable-length encoding.
            uint64,
            /// Uses variable-length encoding. Signed int value. These more
            /// efficiently encode negative numbers than regular `int32`s.
            sint32,
            /// Uses variable-length encoding. Signed int value. These more
            /// efficiently encode negative numbers than regular `int64`s.
            sint64,
            bool,

            /// Uses IEEE 754 single-precision format.
            float,
            /// Uses IEEE 754 double-precision format.
            double,
            /// Always four bytes. More efficient than uint32 if values are often
            /// greater than 2^28.
            fixed32,
            /// Always eight bytes. More efficient than uint64 if values are often
            /// greater than 2^56.
            fixed64,
            /// Always four bytes.
            sfixed32,
            /// Always eight bytes.
            sfixed64,

            /// UTF-8 or 7-bit ASCII. Cannot be longer than 2^32.
            string,
            /// Arbitrary sequence of bytes. Cannot be longer than 2^32.
            bytes,

            pub fn isZigZag(self: @This()) bool {
                return switch (self) {
                    .sint32, .sint64 => true,
                    else => false,
                };
            }

            pub fn isFixed(self: @This()) bool {
                return switch (self) {
                    .float,
                    .fixed32,
                    .sfixed32,
                    .double,
                    .fixed64,
                    .sfixed64,
                    => true,
                    else => false,
                };
            }

            pub fn isNumeric(self: @This()) bool {
                return self != .string and self != .bytes;
            }

            pub fn isSlice(self: @This()) bool {
                return self == .string or self == .bytes;
            }

            pub fn toWire(self: @This()) wire.Type {
                return switch (self) {
                    .int32,
                    .int64,
                    .uint32,
                    .uint64,
                    .sint32,
                    .sint64,
                    .bool,
                    => .varint,
                    .float, .fixed32, .sfixed32 => .i32,
                    .double, .fixed64, .sfixed64 => .i64,
                    .string, .bytes => .len,
                };
            }
        };

    pub const List = union(enum) {
        scalar: Scalar,
        @"enum": void,
        submessage: void,

        pub const Tag = std.meta.Tag(List);
    };
};

/// Structure describing a field. Most of the relevant informations are
/// In the FieldType data. Tag is optional as oneof fields are "virtual" fields.
pub const FieldDescriptor = struct {
    field_number: ?u32,
    ftype: FieldType,
};

/// Helper function to build a FieldDescriptor. Makes code clearer, mostly.
pub fn fd(comptime field_number: ?u32, comptime ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{ .field_number = field_number, .ftype = ftype };
}

// encoding

/// Writes an unsigned varint value.
/// Awaits a u64 value as it's the biggest unsigned varint possible,
// so anything can be cast to it by definition
fn writeRawVarint(writer: std.io.AnyWriter, value: u64) std.io.AnyWriter.Error!void {
    var copy = value;
    while (copy > 0x7F) {
        try writer.writeByte(0x80 + @as(u8, @intCast(copy & 0x7F)));
        copy = copy >> 7;
    }
    try writer.writeByte(@as(u8, @intCast(copy & 0x7F)));
}

/// Writes a varint.
/// Mostly does the required transformations to use writeRawVarint
/// after making the value some kind of unsigned value.
fn writeAsVarint(
    writer: std.io.AnyWriter,
    int: anytype,
    comptime scalar_type: FieldType.Scalar,
) std.io.AnyWriter.Error!void {
    const val: u64 = blk: {
        if (comptime scalar_type.isZigZag()) {
            break :blk wire.ZigZag.encode(int);
        }

        const Int = @TypeOf(int);
        const int_ti = @typeInfo(Int);
        switch (comptime int_ti) {
            .int => |i| {
                if (comptime i.signedness == .signed) {
                    break :blk @bitCast(@as(i64, @intCast(int)));
                } else {
                    break :blk @as(u64, @intCast(int));
                }
            },
            .comptime_int => {
                if (comptime int < 0) {
                    break :blk @bitCast(@as(i64, @intCast(int)));
                } else {
                    break :blk @as(u64, @intCast(int));
                }
            },
            else => unreachable,
        }
    };

    try writeRawVarint(writer, val);
}

/// Write a value of any complex type that can be transfered as a varint
/// Only serves as an indirection to manage Enum and Booleans properly.
fn writeVarint(
    writer: std.io.AnyWriter,
    value: anytype,
    comptime scalar_type: FieldType.Scalar,
) std.io.AnyWriter.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => try writeAsVarint(writer, @as(u8, if (value) 1 else 0), scalar_type),
        .int => try writeAsVarint(writer, value, scalar_type),
        else => @compileError("Should not pass a value of type " ++ @typeInfo(@TypeOf(value)) ++ "here"),
    }
}

/// Writes a fixed size int.
/// Takes care of casting any signed/float value to an appropriate unsigned type
fn writeFixed(writer: std.io.AnyWriter, value: anytype) std.io.AnyWriter.Error!void {
    const bitsize = @bitSizeOf(@TypeOf(value));

    var as_unsigned_int = switch (@TypeOf(value)) {
        f32, f64, i32, i64 => @as(std.meta.Int(.unsigned, bitsize), @bitCast(value)),
        u32, u64, u8 => @as(u64, value),
        else => @compileError("Invalid type for append_fixed"),
    };

    var index: usize = 0;

    while (index < (bitsize / 8)) : (index += 1) {
        try writer.writeByte(@as(u8, @truncate(as_unsigned_int)));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

/// Writes a submessage.
/// Recursively calls encode.
fn writeSubmessage(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    value: anytype,
) (std.mem.Allocator.Error || std.io.AnyWriter.Error)!void {
    // TODO: Better handle calculating submessage size before write, or use
    // fixed-sized buffer.
    var temp_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer temp_buffer.deinit(allocator);
    const w = temp_buffer.writer(allocator);
    try encode(w.any(), allocator, value);
    const size_encoded: u64 = temp_buffer.items.len;
    try writeRawVarint(writer, size_encoded);
    try writer.writeAll(temp_buffer.items);
}

/// simple writing of a list of fixed-size data.
fn writePackedFixedList(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    comptime field: FieldDescriptor,
    value_list: anytype,
) std.io.AnyWriter.Error!void {
    if (value_list.items.len > 0) {
        // first append the tag for the field descriptor
        try writeTag(writer, field);

        var temp_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer temp_buffer.deinit(allocator);
        const w = temp_buffer.writer(allocator);

        // write elements to temporary buffer to calculate write size
        for (value_list.items) |item| {
            try writeFixed(w.any(), item);
        }

        // and finally write the LEN size in the len_index position, followed
        // by the bytes in the temporary buffer
        const size_encoded: u64 = temp_buffer.items.len;
        try writeRawVarint(writer, size_encoded);
        try writer.writeAll(temp_buffer.items);
    }
}

/// Writes a list of varint.
fn writePackedVarintList(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    value_list: anytype,
    comptime field: FieldDescriptor,
    comptime scalar_type: FieldType.Scalar,
) (std.io.AnyWriter.Error || std.mem.Allocator.Error)!void {
    if (value_list.items.len > 0) {
        try writeTag(writer, field);

        var temp_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer temp_buffer.deinit(allocator);

        const w = temp_buffer.writer(allocator);

        for (value_list.items) |item| {
            try writeVarint(w.any(), item, scalar_type);
        }

        const size_encoded: u64 = temp_buffer.items.len;
        try writeRawVarint(writer, size_encoded);
        try writer.writeAll(temp_buffer.items);
    }
}

fn writePackedEnumList(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    value_list: anytype,
    comptime field: FieldDescriptor,
) (std.io.AnyWriter.Error || std.mem.Allocator.Error)!void {
    if (value_list.items.len > 0) {
        try writeTag(writer, field);

        var temp_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer temp_buffer.deinit(allocator);

        const w = temp_buffer.writer(allocator);

        for (value_list.items) |item| {
            try writeRawVarint(w.any(), @bitCast(@as(i64, @intFromEnum(item))));
        }

        const size_encoded: u64 = temp_buffer.items.len;
        try writeRawVarint(writer, size_encoded);
        try writer.writeAll(temp_buffer.items);
    }
}

/// Writes a list of submessages. Sequentially, prepending the tag of each message.
fn writeSubmessageList(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    comptime field: FieldDescriptor,
    value_list: anytype,
) (std.mem.Allocator.Error || std.io.AnyWriter.Error)!void {
    for (value_list.items) |item| {
        try writeTag(writer, field);
        try writeSubmessage(writer, allocator, item);
    }
}

/// Writes a packed list of strings.
fn writePackedStringList(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    comptime field: FieldDescriptor,
    value_list: anytype,
) std.io.AnyWriter!void {
    // TODO: find examples about how to encode and decode packed strings. the documentation is ambiguous
    if (value_list.items.len > 0) {
        try writeTag(writer, field);

        var temp_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer temp_buffer.deinit(allocator);

        const w = temp_buffer.writer(allocator);

        for (value_list.items) |item| {
            try writeRawVarint(w.any(), item.getSlice().len);
            try w.writeAll(item.getSlice());
        }

        const size_encoded: u64 = temp_buffer.items.len;
        try writeRawVarint(writer, size_encoded);
        try writer.writeAll(temp_buffer.items);
    }
}

/// Writes the full tag of the field, if there is any.
fn writeTag(writer: std.io.AnyWriter, comptime field: FieldDescriptor) std.io.AnyWriter.Error!void {
    const tag: wire.Tag = .{
        .type = comptime field.ftype.toWire(),
        .field = field.field_number.?,
    };
    _ = try tag.encode(writer);
}

/// Write a value. Starts by writing the tag, then a comptime switch
/// routes the code to the correct type of data to write.
///
/// force_append is set to true if the field needs to be written regardless of having the default value.
///   it is used when an optional int/bool with value zero need to be encoded. usually value==0 are not written, but optionals
///   require its presence to differentiate 0 from "null"
fn writeValue(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    comptime field: FieldDescriptor,
    value: anytype,
    comptime force_append: bool,
) std.io.AnyWriter.Error!void {

    // TODO: review semantics of default-value in regards to wire protocol
    const is_default_scalar_value = switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        // as per protobuf spec, the first element of the enums must be 0 and it is the default value
        .@"enum" => @intFromEnum(value) == 0,
        else => switch (@TypeOf(value)) {
            bool => value == false,
            i32, u32, i64, u64, f32, f64 => value == 0,
            []const u8 => value.len == 0,
            else => false,
        },
    };

    switch (comptime field.ftype) {
        .scalar => |scalar| {
            if (comptime scalar.isFixed()) {
                if (!is_default_scalar_value or force_append) {
                    try writeTag(writer, field);
                    try writeFixed(writer, value);
                }
            } else if (comptime scalar.isSlice()) {
                if (!is_default_scalar_value or force_append) {
                    try writeTag(writer, field);
                    try writeRawVarint(writer, value.len);
                    try writer.writeAll(value);
                }
            } else {
                if (!is_default_scalar_value or force_append) {
                    try writeTag(writer, field);
                    try writeVarint(writer, value, scalar);
                }
            }
        },
        .@"enum" => {
            if (!is_default_scalar_value or force_append) {
                try writeTag(writer, field);
                try writeRawVarint(writer, @bitCast(@as(i64, @intFromEnum(value))));
            }
        },
        .submessage => {
            if (!is_default_scalar_value or force_append) {
                try writeTag(writer, field);
                try writeSubmessage(writer, allocator, value);
            }
        },
        .packed_list => |list_type| {
            switch (comptime list_type) {
                .scalar => |scalar| {
                    if (comptime scalar.isFixed()) {
                        try writePackedFixedList(writer, allocator, field, value);
                    } else if (comptime scalar.isSlice()) {
                        try writePackedStringList(writer, allocator, field, value);
                    } else {
                        try writePackedVarintList(writer, allocator, value, field, scalar);
                    }
                },
                .@"enum" => {
                    try writePackedEnumList(writer, allocator, value, field);
                },
                .submessage => @compileError("submessages are not suitable for `packed_list`s."),
            }
        },
        .list => |list_type| {
            switch (comptime list_type) {
                .scalar => |scalar| {
                    if (comptime scalar.isFixed()) {
                        for (value.items) |item| {
                            try writeTag(writer, field);
                            try writeFixed(writer, item);
                        }
                    } else if (comptime scalar.isSlice()) {
                        for (value.items) |item| {
                            try writeTag(writer, field);
                            try writeRawVarint(writer, item.len);
                            try writer.writeAll(item);
                        }
                    } else {
                        for (value.items) |item| {
                            try writeTag(writer, field);
                            try writeVarint(writer, item, scalar);
                        }
                    }
                },
                .submessage => {
                    try writeSubmessageList(writer, allocator, field, value);
                },
                .@"enum" => {
                    for (value.items) |item| {
                        try writeTag(writer, field);
                        try writeRawVarint(writer, @bitCast(@as(i64, @intFromEnum(item))));
                    }
                },
            }
        },
        .oneof => |union_type| {
            // iterate over union tags until one matches `active_union_tag` and then use the comptime information to append the value
            const active_union_tag = @tagName(value);
            inline for (@typeInfo(@TypeOf(union_type._desc_table)).@"struct".fields) |union_field| {
                if (std.mem.eql(u8, union_field.name, active_union_tag)) {
                    try writeValue(
                        writer,
                        allocator,
                        @field(union_type._desc_table, union_field.name),
                        @field(value, union_field.name),
                        force_append,
                    );
                }
            }
        },
    }
}

/// Public encoding function, meant to be embedded in generated structs
pub fn encode(
    writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    data: anytype,
) (std.io.AnyWriter.Error || std.mem.Allocator.Error)!void {
    const Data = switch (comptime @typeInfo(@TypeOf(data))) {
        .pointer => |p| p.child,
        else => @TypeOf(data),
    };
    inline for (@typeInfo(Data).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .optional) {
            const temp = data;
            if (@field(temp, field.name)) |value| {
                try writeValue(writer, allocator, @field(Data._desc_table, field.name), value, true);
            }
        } else {
            const value = data;
            try writeValue(writer, allocator, @field(Data._desc_table, field.name), @field(value, field.name), false);
        }
    }
}

fn get_field_default_value(comptime for_type: anytype) for_type {
    return switch (@typeInfo(for_type)) {
        .optional => null,
        // as per protobuf spec, the first element of the enums must be 0 and it is the default value
        .@"enum" => @as(for_type, @enumFromInt(0)),
        else => switch (for_type) {
            bool => false,
            i32, i64, i8, i16, u8, u32, u64, f32, f64 => 0,
            []const u8 => &.{},
            else => undefined,
        },
    };
}

inline fn internal_init(comptime T: type, value: *T) !void {
    if (comptime @typeInfo(T) != .@"struct") {
        @compileError(std.fmt.comptimePrint(
            "Invalid internal init type {s}",
            .{@typeName(T)},
        ));
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (comptime @field(T._desc_table, field.name).ftype) {
            .@"enum", .scalar => {
                if (field.defaultValue()) |val| {
                    @field(value, field.name) = val;
                } else {
                    @field(value, field.name) = get_field_default_value(field.type);
                }
            },
            .submessage => {
                @field(value, field.name) = null;
            },
            .oneof => {
                @field(value, field.name) = null;
            },
            .list, .packed_list => {
                @field(value, field.name) = .empty;
            },
        }
    }
}

/// Generic init function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn init(comptime T: type, allocator: std.mem.Allocator) std.mem.Allocator.Error!T {
    switch (comptime @typeInfo(@TypeOf(T))) {
        .pointer => |p| {
            const value = try allocator.create(p.child);
            try internal_init(p.child, value);
            return value;
        },
        else => {
            var value: T = undefined;
            try internal_init(T, &value);
            return value;
        },
    }
}

/// Generic function to deeply duplicate a message using a new allocator.
/// The original parameter is constant
pub fn dupe(comptime T: type, original: T, allocator: std.mem.Allocator) std.mem.Allocator.Error!T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try dupeField(original, field.name, @field(T._desc_table, field.name).ftype, allocator);
    }

    return result;
}

/// Internal dupe function for a specific field
fn dupeField(
    original: anytype,
    comptime field_name: []const u8,
    comptime ftype: FieldType,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!@TypeOf(@field(original, field_name)) {
    switch (ftype) {
        .@"enum" => return @field(original, field_name),
        .scalar => |scalar| switch (scalar) {
            .string, .bytes => {
                const Original = @TypeOf(original);
                const Field = comptime @FieldType(Original, field_name);
                const field_ti = comptime @typeInfo(Field);
                if (comptime Field == []const u8) {
                    if (comptime @typeInfo(Original) == .@"struct") {
                        const field_info = std.meta.fieldInfo(
                            Original,
                            @field(std.meta.FieldEnum(Original), field_name),
                        );
                        if (comptime field_info.defaultValue()) |val| {
                            if (val.ptr == @field(original, field_name).ptr) {
                                return val;
                            }
                        }
                    }
                    return try allocator.dupe(u8, @field(original, field_name));
                } else switch (comptime field_ti) {
                    .optional => |o| {
                        if (@field(original, field_name)) |val| {
                            if (comptime o.child == []const u8) {
                                if (comptime @typeInfo(Original) == .@"struct") {
                                    const field_info = std.meta.fieldInfo(
                                        Original,
                                        @field(std.meta.FieldEnum(Original), field_name),
                                    );
                                    if (comptime field_info.defaultValue()) |default_opt| {
                                        if (comptime default_opt) |default| {
                                            if (default.ptr == val.ptr) {
                                                return default;
                                            }
                                        }
                                    }
                                }
                                return try allocator.dupe(u8, val);
                            } else {
                                @compileError(std.fmt.comptimePrint(
                                    "invalid string/bytes type {s}",
                                    .{@typeName(Field)},
                                ));
                            }
                        } else {
                            return null;
                        }
                    },
                    else => @compileError(std.fmt.comptimePrint(
                        "invalid string/bytes type {s}",
                        .{@typeName(Field)},
                    )),
                }
            },
            else => return @field(original, field_name),
        },
        .list => |list_type| {
            const capacity = @field(original, field_name).items.len;
            var list = try @TypeOf(@field(original, field_name)).initCapacity(allocator, capacity);
            switch (list_type) {
                .submessage => {
                    for (@field(original, field_name).items) |item| {
                        try list.append(allocator, try item.dupe(allocator));
                    }
                },
                .scalar => |scalar| switch (scalar) {
                    .string, .bytes => {
                        for (@field(original, field_name).items) |item| {
                            try list.append(allocator, try item.dupe(allocator));
                        }
                    },
                    else => {
                        for (@field(original, field_name).items) |item| {
                            try list.append(allocator, item);
                        }
                    },
                },
                .@"enum" => {
                    for (@field(original, field_name).items) |item| {
                        try list.append(allocator, item);
                    }
                },
            }
            return list;
        },
        .packed_list => |_| {
            const capacity = @field(original, field_name).items.len;
            var list = try @TypeOf(@field(original, field_name)).initCapacity(allocator, capacity);

            for (@field(original, field_name).items) |item| {
                try list.append(allocator, item);
            }

            return list;
        },
        .submessage => {
            const Field = comptime @TypeOf(@field(original, field_name));
            const field_ti = comptime @typeInfo(Field);
            switch (comptime field_ti) {
                .optional => |o| {
                    if (@field(original, field_name)) |val| {
                        const Inner = o.child;
                        const inner_ti = comptime @typeInfo(Inner);
                        switch (comptime inner_ti) {
                            .@"struct" => {
                                return try val.dupe(allocator);
                            },
                            // Handle self-referential submessage
                            .pointer => |p| {
                                std.debug.assert(p.size == .one);
                                const result = try allocator.create(p.child);
                                result.* = try val.dupe(allocator);
                                return result;
                            },
                            else => @compileError(std.fmt.comptimePrint(
                                "invalid submessage type {s}",
                                .{@typeName(Field)},
                            )),
                        }
                    } else {
                        return null;
                    }
                },
                // Handle self-referential submessage in "oneof"; non-optional
                // struct pointer in union.
                // Submessages in unions may be non-optional in proto3 and
                // editions, as submessages always have an explicit presence.
                // As such, an "empty" submessage cannot be sent, and the lack
                // of a sent submessage/other union field will be interpreted
                // as the union itself being null.
                .pointer => |p| {
                    comptime std.debug.assert(p.size == .one);
                    const result = try allocator.create(p.child);
                    result.* = try @field(original, field_name).dupe(allocator);
                    return result;
                },
                // Handle submessage in "oneof"; non-optional struct in union.
                // Submessages in unions will be non-optional in proto3 and
                // editions, as submessages always have an explicit presence.
                // As such, an "empty" submessage cannot be sent, and the lack
                // of a sent submessage/other union field will be interpreted
                // as the union itself being null.
                .@"struct" => {
                    return try @field(original, field_name).dupe(allocator);
                },
                else => @compileError(std.fmt.comptimePrint(
                    "invalid submessage type {s}",
                    .{@typeName(Field)},
                )),
            }
        },
        .oneof => |one_of| {
            // if the value is set, inline-iterate over the possible oneofs
            if (@field(original, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(one_of._desc_table)).@"struct".fields) |union_field| {
                    // and if one matches the actual tagName of the union
                    if (std.mem.eql(u8, union_field.name, active)) {
                        // deinit the current value
                        const value = try dupeField(union_value, union_field.name, @field(one_of._desc_table, union_field.name).ftype, allocator);

                        return @unionInit(one_of, union_field.name, value);
                    }
                }
            }
            return null;
        },
    }
}

/// Generic deinit function. Properly cleans any field required. Meant to be embedded in generated structs.
pub fn deinit(allocator: std.mem.Allocator, data: anytype) void {
    const T = @typeInfo(@TypeOf(data)).pointer.child;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        deinitField(allocator, data, field.name);
    }
}

fn deinitField(
    allocator: std.mem.Allocator,
    root: anytype,
    comptime field_name: []const u8,
) void {
    const Root = if (comptime @typeInfo(@TypeOf(root)) == .pointer)
        @typeInfo(@TypeOf(root)).pointer.child
    else
        @TypeOf(root);
    const root_ti = @typeInfo(Root);
    const desc: FieldDescriptor = @field(Root._desc_table, field_name);
    const Field = @FieldType(Root, field_name);
    const ti = @typeInfo(Field);

    comptime std.debug.assert(root_ti == .@"struct" or root_ti == .@"union");

    switch (comptime ti) {
        .bool, .int, .@"enum", .float => {},
        .pointer => |p| {
            const child_ti = @typeInfo(p.child);
            switch (p.size) {
                .one => {
                    comptime std.debug.assert(child_ti == .@"struct");
                    comptime std.debug.assert(desc.ftype == .submessage);
                    @field(root, field_name).deinit(allocator);
                    allocator.destroy(@field(root, field_name));
                },
                .slice => {
                    comptime std.debug.assert(
                        // TODO: Use slices instead of `ArrayListUnmanaged`
                        // for (packed) lists.
                        // desc.ftype == .list or
                        // desc.ftype == .packed_list or
                        (desc.ftype == .scalar and
                            (desc.ftype.scalar == .string or desc.ftype.scalar == .bytes)),
                    );
                    const slc: []const p.child = @field(root, field_name);
                    if (slc.len == 0) return;

                    if (comptime root_ti == .@"struct") {
                        const field_info = comptime std.meta.fieldInfo(
                            Root,
                            @field(std.meta.FieldEnum(Root), field_name),
                        );

                        if (comptime field_info.defaultValue()) |default| {
                            if (comptime default.len > 0) {
                                if (default.ptr == slc.ptr) return;
                            }
                        }
                    }

                    switch (comptime child_ti) {
                        .@"struct" => {
                            // Maps cannot be repeated; this is guaranteed
                            // to be a slice of submessages.
                            comptime std.debug.assert(desc.ftype == .list);
                            for (slc) |*item| {
                                item.deinit(allocator);
                            }
                        },
                        .pointer => |pi| {
                            // `repeated` cannot be directly nested; this
                            // is guaranteed to be `string` or `bytes`.
                            comptime std.debug.assert(pi.child == u8);
                            for (slc) |item| {
                                if (item.len > 0) allocator.free(item);
                            }
                        },
                        .bool, .int, .@"enum", .float => {},
                        else => unreachable,
                    }

                    allocator.free(slc);
                },
                .many, .c => unreachable,
            }
        },
        .optional => |o| {
            if (@field(root, field_name) == null) return;
            const child_ti = @typeInfo(o.child);
            switch (comptime child_ti) {
                .pointer => |p| {
                    if (comptime p.size == .one) {
                        comptime std.debug.assert(@typeInfo(p.child) == .@"struct");
                        comptime std.debug.assert(desc.ftype == .submessage);

                        @field(root, field_name).?.deinit(allocator);
                        allocator.destroy(@field(root, field_name).?);
                    } else if (comptime p.size == .slice) {
                        // Only strings/bytes may be optional slices. Lists
                        // and packed lists cannot be optional.
                        comptime std.debug.assert(p.child == u8);

                        if (comptime root_ti == .@"struct") {
                            const field_info = comptime std.meta.fieldInfo(
                                Root,
                                @field(std.meta.FieldEnum(Root), field_name),
                            );

                            if (comptime field_info.defaultValue()) |default| {
                                if (comptime default != null and default.?.len > 0) {
                                    if (default.?.ptr == @field(root, field_name).?.ptr) return;
                                }
                            }
                        }

                        if (@field(root, field_name).?.len > 0)
                            allocator.free(@field(root, field_name).?);
                    } else unreachable;
                },
                .@"struct" => |s| {
                    // If arraylist, also free items inside.
                    if (comptime s.fields.len == 2 and
                        @hasField(o.child, "items") and @hasField(o.child, "capacity"))
                    {
                        std.log.err("list of strings deinit", .{});
                        const ListItem = @typeInfo(@FieldType(o.child, "items")).pointer.child;
                        switch (comptime @typeInfo(ListItem)) {
                            .pointer => {
                                std.debug.assert(ListItem == []const u8);
                                for (@field(root, field_name).?.items) |item| {
                                    if (item.len > 0) allocator.free(item);
                                }
                            },
                            .@"struct" => {
                                for (@field(root, field_name).?.items) |*item| {
                                    item.deinit(allocator);
                                }
                            },
                            else => unreachable,
                        }
                    }
                    @field(root, field_name).?.deinit(allocator);
                },
                .@"union" => {
                    switch (@field(root, field_name).?) {
                        inline else => |_, active| {
                            deinitField(allocator, &@field(root, field_name).?, @tagName(active));
                        },
                    }
                },
                .@"enum", .bool, .int, .float => {},
                else => unreachable,
            }
        },
        // Maps, `oneof` submessages, and `ArrayListUnmanaged`s
        .@"struct" => |s| {
            // If arraylist, also free items inside.
            if (comptime s.fields.len == 2 and
                @hasField(Field, "items") and @hasField(Field, "capacity"))
            {
                const ListItem = @typeInfo(@FieldType(Field, "items")).pointer.child;
                switch (comptime @typeInfo(ListItem)) {
                    .pointer => {
                        std.debug.assert(ListItem == []const u8);
                        for (@field(root, field_name).items) |item| {
                            if (item.len > 0) allocator.free(item);
                        }
                    },
                    .@"struct" => {
                        for (@field(root, field_name).items) |*item| {
                            item.deinit(allocator);
                        }
                    },
                    .bool, .@"enum", .float, .int => {},
                    else => unreachable,
                }
            }
            @field(root, field_name).deinit(allocator);
        },
        else => unreachable,
    }
}

// decoding

/// Enum describing if described data is raw (<u64) data or a byte slice.
const ExtractedDataTag = enum {
    RawValue,
    Slice,
};

/// Union enclosing either a u64 raw value, or a byte slice.
const ExtractedData = union(ExtractedDataTag) { RawValue: u64, Slice: []const u8 };

/// Unit of extracted data from a stream
const Extracted = struct { tag: wire.Tag, field_number: u32, data: ExtractedData };

/// Decoded varint value generic type
fn DecodedVarint(comptime T: type) type {
    return struct {
        value: T,
        size: usize,
    };
}

/// Decodes a varint from a slice, to type T.
fn decode_varint(comptime T: type, input: []const u8) DecodingError!DecodedVarint(T) {
    var index: usize = 0;
    const len: usize = input.len;

    var shift: u32 = 0;
    var value: T = 0;
    while (true) {
        if (index >= len) return error.NotEnoughData;
        const b = input[index];
        if (shift >= @bitSizeOf(T)) {
            // We are casting more bits than the type can handle
            // It means the "@intCast(shift)" will throw a fatal error
            return error.InvalidInput;
        }
        value += (@as(T, input[index] & 0x7F)) << (@as(std.math.Log2Int(T), @intCast(shift)));
        index += 1;
        if (b >> 7 == 0) break;
        shift += 7;
    }

    return DecodedVarint(T){
        .value = value,
        .size = index,
    };
}

/// Decodes a fixed value to type T
fn decode_fixed(comptime T: type, slice: []const u8) T {
    const result_base: type = switch (@bitSizeOf(T)) {
        32 => u32,
        64 => u64,
        else => @compileError("can only manage 32 or 64 bit sizes"),
    };
    var result: result_base = 0;

    for (slice, 0..) |byte, index| {
        result += @as(result_base, @intCast(byte)) << (@as(std.math.Log2Int(result_base), @intCast(index * 8)));
    }

    return switch (T) {
        u32, u64 => result,
        else => @as(T, @bitCast(result)),
    };
}

fn FixedDecoderIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        const num_bytes = @divFloor(@bitSizeOf(T), 8);

        input: []const u8,
        current_index: usize = 0,

        fn next(self: *Self) ?T {
            if (self.current_index < self.input.len) {
                defer self.current_index += Self.num_bytes;
                return decode_fixed(T, self.input[self.current_index .. self.current_index + Self.num_bytes]);
            }
            return null;
        }
    };
}

fn VarintDecoderIterator(comptime T: type, comptime scalar_type: FieldType.Scalar) type {
    return struct {
        const Self = @This();

        input: []const u8,
        current_index: usize = 0,

        fn next(self: *Self) DecodingError!?T {
            if (self.current_index < self.input.len) {
                const raw_value = try decode_varint(u64, self.input[self.current_index..]);
                defer self.current_index += raw_value.size;
                return try decode_varint_value(T, scalar_type, raw_value.value);
            }
            return null;
        }
    };
}

const LengthDelimitedDecoderIterator = struct {
    const Self = @This();

    input: []const u8,
    current_index: usize = 0,

    fn next(self: *Self) DecodingError!?[]const u8 {
        if (self.current_index < self.input.len) {
            const size = try decode_varint(u64, self.input[self.current_index..]);
            self.current_index += size.size;
            defer self.current_index += size.value;

            if (self.current_index > self.input.len or (self.current_index + size.value) > self.input.len) return error.NotEnoughData;

            return self.input[self.current_index .. self.current_index + size.value];
        }
        return null;
    }
};

/// "Tokenizer" of a byte slice to raw pb data.
pub const WireDecoderIterator = struct {
    input: []const u8,
    current_index: usize = 0,

    /// Attempts at decoding the next pb_buffer data.
    pub fn next(state: *WireDecoderIterator) DecodingError!?Extracted {
        if (state.current_index < state.input.len) {
            var fbs = std.io.fixedBufferStream(state.input[state.current_index..]);
            const reader = fbs.reader();
            const tag: wire.Tag = wire.Tag.decode(reader.any()) catch |e| switch (e) {
                error.InvalidTag => return DecodingError.InvalidInput,
                else => unreachable,
            };
            state.current_index += if (tag.field > 2047) 3 else if (tag.field > 15) 2 else 1;
            const data: ExtractedData = switch (tag.type) {
                .varint => blk: { // VARINT
                    const varint = try decode_varint(u64, state.input[state.current_index..]);
                    state.current_index += varint.size;
                    break :blk ExtractedData{
                        .RawValue = varint.value,
                    };
                },
                .i64 => blk: { // 64BIT
                    const value = ExtractedData{ .RawValue = decode_fixed(u64, state.input[state.current_index .. state.current_index + 8]) };
                    state.current_index += 8;
                    break :blk value;
                },
                .len => blk: { // LEN PREFIXED MESSAGE
                    const size = try decode_varint(u32, state.input[state.current_index..]);
                    const start = (state.current_index + size.size);
                    const end = start + size.value;

                    if (state.input.len < start or state.input.len < end) {
                        return error.NotEnoughData;
                    }

                    const value = ExtractedData{ .Slice = state.input[start..end] };
                    state.current_index += size.value + size.size;
                    break :blk value;
                },
                .sgroup, .egroup => return null,
                .i32 => blk: { // 32BIT
                    const value = ExtractedData{ .RawValue = decode_fixed(u32, state.input[state.current_index .. state.current_index + 4]) };
                    state.current_index += 4;
                    break :blk value;
                },
            };

            return Extracted{ .tag = tag, .data = data, .field_number = tag.field };
        } else {
            return null;
        }
    }
};

/// Get a real varint of type T from a raw u64 data.
fn decode_varint_value(comptime T: type, comptime scalar_type: FieldType.Scalar, raw: u64) DecodingError!T {
    if (comptime scalar_type.isZigZag()) {
        return wire.ZigZag.decode(T, raw);
    }
    if (comptime T == bool) {
        return raw != 0;
    }
    if (comptime T == i64) {
        return @bitCast(raw);
    }
    if (comptime T == i32) {
        return std.math.cast(i32, @as(i64, @bitCast(raw))) orelse error.InvalidInput;
    }
    const ti = comptime @typeInfo(T);
    switch (comptime ti) {
        .int => |i| {
            if (comptime i.signedness == .unsigned) {
                return @as(T, @intCast(raw));
            } else unreachable;
        },
        .@"enum" => {
            const as_u32: u32 = std.math.cast(u32, raw) orelse return DecodingError.InvalidInput;
            return std.meta.intToEnum(T, @as(i32, @bitCast(as_u32))) catch DecodingError.InvalidInput;
        },
        else => unreachable,
    }
}

/// Get a real fixed value of type T from a raw u64 value.
fn decode_fixed_value(comptime T: type, raw: u64) T {
    return switch (T) {
        i32, u32, f32 => @as(T, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(raw)))),
        i64, f64, u64 => @as(T, @bitCast(raw)),
        bool => raw != 0,
        else => @as(T, @bitCast(raw)),
    };
}

/// this function receives a slice of a message and decodes one by one the elements of the packet list until the slice is exhausted
fn decode_packed_list(
    slice: []const u8,
    comptime list_type: FieldType.List,
    comptime T: type,
    array: *std.ArrayListUnmanaged(T),
    allocator: std.mem.Allocator,
) (DecodingError || std.mem.Allocator.Error)!void {
    switch (comptime list_type) {
        .scalar => |scalar| {
            if (comptime scalar.isFixed()) {
                switch (comptime T) {
                    u32, i32, u64, i64, f32, f64 => {
                        var fixed_iterator = FixedDecoderIterator(T){ .input = slice };
                        while (fixed_iterator.next()) |value| {
                            try array.append(allocator, value);
                        }
                    },
                    else => @compileError("Type not accepted for FixedInt: " ++ @typeName(T)),
                }
            } else if (comptime scalar.isSlice()) {
                var varint_iterator = LengthDelimitedDecoderIterator{ .input = slice };
                while (try varint_iterator.next()) |value| {
                    try array.append(allocator, try allocator.dupe(u8, value));
                }
            } else {
                var varint_iterator = VarintDecoderIterator(T, scalar){ .input = slice };
                while (try varint_iterator.next()) |value| {
                    try array.append(allocator, value);
                }
            }
        },
        .@"enum" => {
            var varint_iterator = VarintDecoderIterator(T, .int32){ .input = slice };
            while (try varint_iterator.next()) |value| {
                try array.append(allocator, value);
            }
        },
        .submessage =>
        // submessages are not suitable for packed lists yet, but the wire message can be malformed
        return error.InvalidInput,
    }
}

/// decode_value receives
fn decode_value(
    comptime Decoded: type,
    comptime ftype: FieldType,
    extracted_data: Extracted,
    allocator: std.mem.Allocator,
) (DecodingError || std.mem.Allocator.Error)!Decoded {
    switch (ftype) {
        .scalar => |scalar| {
            if (comptime scalar.isFixed()) {
                return switch (extracted_data.data) {
                    .RawValue => |value| decode_fixed_value(Decoded, value),
                    .Slice => error.InvalidInput,
                };
            } else if (comptime scalar.isSlice()) {
                return switch (extracted_data.data) {
                    .Slice => |slice| try allocator.dupe(u8, slice),
                    .RawValue => error.InvalidInput,
                };
            } else {
                return switch (extracted_data.data) {
                    .RawValue => |value| try decode_varint_value(Decoded, scalar, value),
                    .Slice => error.InvalidInput,
                };
            }
        },
        .@"enum" => return switch (extracted_data.data) {
            .RawValue => |value| try decode_varint_value(Decoded, .int32, value),
            .Slice => error.InvalidInput,
        },

        .submessage => return switch (extracted_data.data) {
            .Slice => |slice| b: {
                switch (comptime @typeInfo(Decoded)) {
                    .@"struct" => {
                        break :b try decode(Decoded, slice, allocator);
                    },
                    .pointer => |p| {
                        comptime std.debug.assert(p.size == .one);
                        const result: *p.child = try allocator.create(p.child);
                        errdefer allocator.destroy(result);
                        result.* = try decode(p.child, slice, allocator);
                        break :b result;
                    },
                    .optional => |o| {
                        const Inner = o.child;
                        switch (comptime @typeInfo(Inner)) {
                            .@"struct" => {
                                break :b try decode(Inner, slice, allocator);
                            },
                            .pointer => |p| {
                                comptime std.debug.assert(p.size == .one);
                                const result: *p.child = try allocator.create(p.child);
                                errdefer allocator.destroy(result);
                                result.* = try decode(p.child, slice, allocator);
                                break :b result;
                            },
                            else => {
                                @compileError(std.fmt.comptimePrint(
                                    "invalid submessage field {s}",
                                    .{@typeName(Decoded)},
                                ));
                            },
                        }
                    },
                    else => {
                        @compileError(std.fmt.comptimePrint(
                            "invalid submessage field {s}",
                            .{@typeName(Decoded)},
                        ));
                    },
                }
            },
            .RawValue => return error.InvalidInput,
        },
        .list, .packed_list, .oneof => {
            log.err("Invalid scalar type {any}\n", .{ftype});
            return error.InvalidInput;
        },
    }
}

fn decode_data(
    comptime T: type,
    comptime field_desc: FieldDescriptor,
    comptime field: std.builtin.Type.StructField,
    result: *T,
    extracted_data: Extracted,
    allocator: std.mem.Allocator,
) (DecodingError || std.mem.Allocator.Error)!void {
    switch (comptime field_desc.ftype) {
        .scalar, .@"enum", .submessage => {
            // first try to release the current value
            deinitField(allocator, result, field.name);

            // then apply the new value
            switch (@typeInfo(field.type)) {
                .optional => |optional| @field(result, field.name) = try decode_value(optional.child, field_desc.ftype, extracted_data, allocator),
                else => @field(result, field.name) = try decode_value(field.type, field_desc.ftype, extracted_data, allocator),
            }
        },
        .list, .packed_list => |list_type| {
            const child_type = @typeInfo(@TypeOf(@field(result, field.name).items)).pointer.child;

            switch (comptime list_type) {
                .scalar => |scalar| {
                    if (comptime scalar.isSlice()) {
                        switch (extracted_data.data) {
                            .Slice => |slice| {
                                try @field(result, field.name).append(allocator, try allocator.dupe(u8, slice));
                            },
                            .RawValue => return error.InvalidInput,
                        }
                    } else if (comptime scalar.isFixed()) {
                        switch (extracted_data.data) {
                            .RawValue => |value| try @field(result, field.name).append(allocator, decode_fixed_value(child_type, value)),
                            .Slice => |slice| try decode_packed_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                        }
                    } else {
                        switch (extracted_data.data) {
                            .RawValue => |value| try @field(result, field.name).append(allocator, try decode_varint_value(child_type, scalar, value)),
                            .Slice => |slice| try decode_packed_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                        }
                    }
                },
                .@"enum" => switch (extracted_data.data) {
                    .RawValue => |value| try @field(result, field.name).append(allocator, try decode_varint_value(child_type, .int32, value)),
                    .Slice => |slice| try decode_packed_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                },
                .submessage => switch (extracted_data.data) {
                    .Slice => |slice| {
                        try @field(result, field.name).append(allocator, try child_type.decode(slice, allocator));
                    },
                    .RawValue => return error.InvalidInput,
                },
            }
        },
        .oneof => |one_of| {
            // the following code:
            // 1. creates a compile time for iterating over all `one_of._desc_table` fields
            // 2. when a match is found, it creates the union value in the `field.name` property of the struct `result`. breaks the for at that point
            const desc_union = one_of._desc_table;
            inline for (@typeInfo(one_of).@"union".fields) |union_field| {
                const v = @field(desc_union, union_field.name);
                if (is_tag_known(v, extracted_data)) {
                    // deinit the current value of the enum to prevent leaks
                    deinitField(allocator, result, field.name);

                    // and decode & assign the new value
                    const value = try decode_value(union_field.type, v.ftype, extracted_data, allocator);
                    @field(result, field.name) = @unionInit(one_of, union_field.name, value);
                }
            }
        },
    }
}

inline fn is_tag_known(comptime field_desc: FieldDescriptor, tag_to_check: Extracted) bool {
    if (field_desc.field_number) |field_number| {
        return field_number == tag_to_check.field_number;
    } else {
        const desc_union = field_desc.ftype.oneof._desc_table;
        inline for (@typeInfo(@TypeOf(desc_union)).@"struct".fields) |union_field| {
            if (is_tag_known(@field(desc_union, union_field.name), tag_to_check)) {
                return true;
            }
        }
    }

    return false;
}

/// public decoding function meant to be embedded in message structures
/// Iterates over the input and try to fill the resulting structure accordingly.
pub fn decode(
    comptime T: type,
    input: []const u8,
    allocator: std.mem.Allocator,
) (DecodingError || std.mem.Allocator.Error)!T {
    var result = try init(T, allocator);

    var iterator = WireDecoderIterator{ .input = input };

    while (try iterator.next()) |extracted_data| {
        const rootType = T;
        inline for (@typeInfo(rootType).@"struct".fields) |field| {
            const v = @field(rootType._desc_table, field.name);
            if (is_tag_known(v, extracted_data)) {
                break try decode_data(rootType, v, field, &result, extracted_data, allocator);
            }
        } else {
            log.debug("Unknown field received in {s} {any}\n", .{ @typeName(T), extracted_data.tag });
        }
    }

    return result;
}

test "get varint" {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(std.testing.allocator);

    const w = pb.writer(std.testing.allocator);

    try writeVarint(w.any(), @as(i32, 0x12c), .int32);
    try writeVarint(w.any(), @as(i32, 0x0), .int32);
    try writeVarint(w.any(), @as(i32, 0x1), .int32);
    try writeVarint(w.any(), @as(i32, 0xA1), .int32);
    try writeVarint(w.any(), @as(i32, 0xFF), .int32);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0b10101100, 0b00000010, 0x0, 0x1, 0xA1, 0x1, 0xFF, 0x01 }, pb.items);
}

test writeRawVarint {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(std.testing.allocator);

    var w = pb.writer(std.testing.allocator);

    try writeRawVarint(w.any(), 3);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, pb.items);
    try writeRawVarint(w.any(), 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1 }, pb.items);
    try writeRawVarint(w.any(), 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1, 0x0 }, pb.items);
    try writeRawVarint(w.any(), 0x80);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1, 0x0, 0x80, 0x1 }, pb.items);
    try writeRawVarint(w.any(), 0xffffffff);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x3,
        0x1,
        0x0,
        0x80,
        0x1,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x0F,
    }, pb.items);
}

test "encode and decode multiple varints" {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(std.testing.allocator);

    const w = pb.writer(std.testing.allocator);

    const list = &[_]u64{ 0, 1, 2, 3, 199, 0xff, 0xfa, 1231313, 999288361, 0, 0xfffffff, 0x80808080, 0xffffffff };

    for (list) |num|
        try writeVarint(w.any(), num, .uint64);

    var demo = VarintDecoderIterator(u64, .uint64){ .input = pb.items };

    for (list) |num|
        try std.testing.expectEqual(num, (try demo.next()).?);

    try std.testing.expectEqual(demo.next(), null);
}

test VarintDecoderIterator {
    var demo = VarintDecoderIterator(u64, .uint64){ .input = "\x01\x02\x03\x04\xA1\x01" };
    try std.testing.expectEqual(demo.next(), 1);
    try std.testing.expectEqual(demo.next(), 2);
    try std.testing.expectEqual(demo.next(), 3);
    try std.testing.expectEqual(demo.next(), 4);
    try std.testing.expectEqual(demo.next(), 0xA1);
    try std.testing.expectEqual(demo.next(), null);
}

// TODO: the following two tests should work
// test "VarintDecoderIterator i32" {
//     var demo = VarintDecoderIterator(i32, .ZigZagOptimized){ .input = &[_]u8{ 133, 255, 255, 255, 255, 255, 255, 255, 255, 1 } };
//     try testing.expectEqual(demo.next(), -123);
//     try testing.expectEqual(demo.next(), null);
// }
// test "VarintDecoderIterator i64" {
//     var demo = VarintDecoderIterator(i64, .ZigZagOptimized){ .input = &[_]u8{ 133, 255, 255, 255, 255, 255, 255, 255, 255, 1 } };
//     try testing.expectEqual(demo.next(), -123);
//     try testing.expectEqual(demo.next(), null);
// }

test FixedDecoderIterator {
    var demo = FixedDecoderIterator(i64){ .input = &[_]u8{ 133, 255, 255, 255, 255, 255, 255, 255 } };
    try std.testing.expectEqual(demo.next(), -123);
    try std.testing.expectEqual(demo.next(), null);
}

// length delimited message including a list of varints
test "unit varint packed - decode - multi-byte-varint" {
    const bytes = &[_]u8{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
    var list: std.ArrayListUnmanaged(u32) = .empty;
    defer list.deinit(std.testing.allocator);

    try decode_packed_list(bytes, .{ .scalar = .uint32 }, u32, &list, std.testing.allocator);

    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 270, 86942 }, list.items);
}

test "decode fixed" {
    const u_32 = [_]u8{ 2, 0, 0, 0 };
    const u_32_result: u32 = 2;
    try std.testing.expectEqual(u_32_result, decode_fixed(u32, &u_32));

    const u_64 = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const u_64_result: u64 = 1;
    try std.testing.expectEqual(u_64_result, decode_fixed(u64, &u_64));

    const i_32 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const i_32_result: i32 = -1;
    try std.testing.expectEqual(i_32_result, decode_fixed(i32, &i_32));

    const i_64 = [_]u8{ 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const i_64_result: i64 = -2;
    try std.testing.expectEqual(i_64_result, decode_fixed(i64, &i_64));

    const f_32 = [_]u8{ 0x00, 0x00, 0xa0, 0x40 };
    const f_32_result: f32 = 5.0;
    try std.testing.expectEqual(f_32_result, decode_fixed(f32, &f_32));

    const f_64 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x40 };
    const f_64_result: f64 = 5.0;
    try std.testing.expectEqual(f_64_result, decode_fixed(f64, &f_64));
}

test "zigzag i32 - encode" {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(std.testing.allocator);

    const w = pb.writer(std.testing.allocator);

    const input = "\xE7\x07";

    // -500 (.ZigZag)  encodes to {0xE7,0x07} which equals to 999 (.Simple)

    try writeAsVarint(w.any(), @as(i32, -500), .sint32);
    try std.testing.expectEqualSlices(u8, input, pb.items);
}

test "zigzag i32/i64 - decode" {
    try std.testing.expectEqual(@as(i32, 1), try decode_varint_value(i32, .sint32, 2));
    try std.testing.expectEqual(@as(i32, -2), try decode_varint_value(i32, .sint32, 3));
    try std.testing.expectEqual(@as(i32, -500), try decode_varint_value(i32, .sint32, 999));
    try std.testing.expectEqual(@as(i64, -500), try decode_varint_value(i64, .sint64, 999));
    try std.testing.expectEqual(@as(i64, -500), try decode_varint_value(i64, .sint64, 999));
    try std.testing.expectEqual(@as(i64, -0x80000000), try decode_varint_value(i64, .sint64, 0xffffffff));
}

test "zigzag i64 - encode" {
    var pb: std.ArrayListUnmanaged(u8) = .empty;
    defer pb.deinit(std.testing.allocator);

    const w = pb.writer(std.testing.allocator);

    const input = "\xE7\x07";

    // -500 (.ZigZag)  encodes to {0xE7,0x07} which equals to 999 (.Simple)

    try writeAsVarint(w.any(), @as(i64, -500), .sint64);
    try std.testing.expectEqualSlices(u8, input, pb.items);
}

test "incorrect data - decode" {
    const input = "\xFF\xFF\xFF\xFF\xFF\x01";
    const value = decode_varint(u32, input);

    try std.testing.expectError(error.InvalidInput, value);
}

test "incorrect data - simple varint" {
    // Incorrectly serialized protobufs can place a varint with a decoded value
    // greater than std.math.maxInt(u32) into the slot an enum is supposed to
    // fill. Since this library represents a decoded varint as a u64 -- the max
    // possible valid varint width -- that data can make its way deep into the
    // decode_varint_value routine. This test checks that we handle such failures
    // gracefully rather than panicking.
    const max_u64 = decode_varint_value(enum(i32) { a, b, c }, .int32, (1 << 64) - 1);
    const barely_too_big = decode_varint_value(enum(i32) { a, b, c }, .int32, 1 << 32);

    try std.testing.expectError(error.InvalidInput, max_u64);
    try std.testing.expectError(error.InvalidInput, barely_too_big);
}

test "correct data - simple varint" {
    const enum_a = try decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, (1 << 32) - 1);
    const enum_b = try decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, 0);
    const enum_c = try decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, 1);
    const enum_d = try decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, 2);

    try std.testing.expectEqual(.a, enum_a);
    try std.testing.expectEqual(.b, enum_b);
    try std.testing.expectEqual(.c, enum_c);
    try std.testing.expectEqual(.d, enum_d);
}

test "invalid enum values" {
    try std.testing.expectError(
        DecodingError.InvalidInput,
        decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, (1 << 64) - 1),
    );
    try std.testing.expectError(
        DecodingError.InvalidInput,
        decode_varint_value(enum(i32) { a = -1, b = 0, c = 1, d = 2 }, .int32, 4),
    );
}

test {
    _ = wire;
    _ = json;
}
