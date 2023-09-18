const std = @import("std");
const StructField = std.builtin.Type.StructField;
const isSignedInt = std.meta.trait.isSignedInt;
const isIntegral = std.meta.trait.isIntegral;
const Allocator = std.mem.Allocator;
const testing = std.testing;

// common definitions

const ArrayList = std.ArrayList;

/// Type of encoding for a Varint value.
const VarintType = enum { Simple, ZigZagOptimized };

const DecodingError = error{ NotEnoughData, InvalidInput };

const UnionDecodingError = DecodingError || Allocator.Error;

pub const ManagedStringTag = enum { Owned, Const, Empty };

pub const AllocatedString = struct { allocator: Allocator, str: []const u8 };

pub const ManagedString = union(ManagedStringTag) {
    Owned: AllocatedString,
    Const: []const u8,
    Empty,

    /// copies the provided string using the allocator. the `src` parameter should be freed by the caller
    pub fn copy(str: []const u8, allocator: Allocator) !ManagedString {
        return ManagedString{ .Owned = AllocatedString{ .str = try allocator.dupe(u8, str), .allocator = allocator } };
    }

    /// moves the ownership of the string to the message. the caller MUST NOT free the provided string
    pub fn move(str: []const u8, allocator: Allocator) ManagedString {
        return ManagedString{ .Owned = AllocatedString{ .str = str, .allocator = allocator } };
    }

    /// creates a static string from a compile time const
    pub fn static(comptime str: []const u8) ManagedString {
        return ManagedString{ .Const = str };
    }

    /// creates a static string that will not be released by calling .deinit()
    pub fn managed(str: []const u8) ManagedString {
        return ManagedString{ .Const = str };
    }

    pub fn isEmpty(self: ManagedString) bool {
        return self.getSlice().len == 0;
    }

    pub fn getSlice(self: ManagedString) []const u8 {
        switch (self) {
            .Owned => |alloc_str| return alloc_str.str,
            .Const => |slice| return slice,
            .Empty => return "",
        }
    }

    pub fn dupe(self: ManagedString, allocator: Allocator) !ManagedString {
        switch (self) {
            .Owned => |alloc_str| if (alloc_str.str.len == 0) {
                return .Empty;
            } else {
                return copy(alloc_str.str, allocator);
            },
            .Const, .Empty => return self,
        }
    }

    pub fn deinit(self: ManagedString) void {
        switch (self) {
            .Owned => |alloc_str| {
                alloc_str.allocator.free(alloc_str.str);
            },
            else => {},
        }
    }
};

/// Enum describing the different field types available.
pub const FieldTypeTag = enum { Varint, FixedInt, SubMessage, String, List, PackedList, OneOf };

/// Enum describing how much bits a FixedInt will use.
pub const FixedSize = enum(u3) { I64 = 1, I32 = 5 };

/// Enum describing the content type of a repeated field.
pub const ListTypeTag = enum {
    Varint,
    String,
    FixedInt,
    SubMessage,
};

/// Tagged union for repeated fields, giving the details of the underlying type.
pub const ListType = union(ListTypeTag) {
    Varint: VarintType,
    String,
    FixedInt: FixedSize,
    SubMessage,
};

/// Main tagged union holding the details of any field type.
pub const FieldType = union(FieldTypeTag) {
    Varint: VarintType,
    FixedInt: FixedSize,
    SubMessage,
    String,
    List: ListType,
    PackedList: ListType,
    OneOf: type,

    /// returns the wire type of a field. see https://developers.google.com/protocol-buffers/docs/encoding#structure
    pub fn get_wirevalue(comptime ftype: FieldType) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => |size| @intFromEnum(size),
            .String, .SubMessage, .PackedList => 2,
            .List => |inner| switch (inner) {
                .Varint => 0,
                .FixedInt => |size| @intFromEnum(size),
                .String, .SubMessage => 2,
            },
            .OneOf => @compileError("Shouldn't pass a .OneOf field to this function here."),
        };
    }
};

/// Structure describing a field. Most of the relevant informations are
/// In the FieldType data. Tag is optional as OneOf fields are "virtual" fields.
pub const FieldDescriptor = struct {
    field_number: ?u32,
    ftype: FieldType,
};

/// Helper function to build a FieldDescriptor. Makes code clearer, mostly.
pub fn fd(comptime field_number: ?u32, comptime ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{ .field_number = field_number, .ftype = ftype };
}

// encoding

/// Appends an unsigned varint value.
/// Awaits a u64 value as it's the biggest unsigned varint possible,
// so anything can be cast to it by definition
fn append_raw_varint(pb: *ArrayList(u8), value: u64) !void {
    var copy = value;
    while (copy > 0x7F) {
        try pb.append(0x80 + @as(u8, @intCast(copy & 0x7F)));
        copy = copy >> 7;
    }
    try pb.append(@as(u8, @intCast(copy & 0x7F)));
}

/// Inserts a varint into the pb at start_index
/// Mostly useful when inserting the size of a field after it has been
/// Appended to the pb buffer.
fn insert_raw_varint(pb: *ArrayList(u8), size: u64, start_index: usize) !void {
    if (size < 0x7F) {
        try pb.insert(start_index, @as(u8, @truncate(size)));
    } else {
        var copy = size;
        var index = start_index;
        while (copy > 0x7F) : (index += 1) {
            try pb.insert(index, 0x80 + @as(u8, @intCast(copy & 0x7F)));
            copy = copy >> 7;
        }
        try pb.insert(index, @as(u8, @intCast(copy & 0x7F)));
    }
}

/// Appends a varint to the pb array.
/// Mostly does the required transformations to use append_raw_varint
/// after making the value some kind of unsigned value.
fn append_as_varint(pb: *ArrayList(u8), int: anytype, comptime varint_type: VarintType) !void {
    const type_of_val = @TypeOf(int);
    const bitsize = @bitSizeOf(type_of_val);
    const val: u64 = blk: {
        if (isSignedInt(type_of_val)) {
            switch (varint_type) {
                .ZigZagOptimized => {
                    break :blk @as(u64, @intCast((int >> (bitsize - 1)) ^ (int << 1)));
                },
                .Simple => {
                    break :blk @as(std.meta.Int(.unsigned, bitsize), @bitCast(int));
                },
            }
        } else {
            break :blk @as(u64, @intCast(int));
        }
    };

    try append_raw_varint(pb, val);
}

/// Append a value of any complex type that can be transfered as a varint
/// Only serves as an indirection to manage Enum and Booleans properly.
fn append_varint(pb: *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @as(i32, @intFromEnum(value)), varint_type),
        .Bool => try append_as_varint(pb, @as(u8, if (value) 1 else 0), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

/// Appends a fixed size int to the pb buffer.
/// Takes care of casting any signed/float value to an appropriate unsigned type
fn append_fixed(pb: *ArrayList(u8), value: anytype) !void {
    const bitsize = @bitSizeOf(@TypeOf(value));

    var as_unsigned_int = switch (@TypeOf(value)) {
        f32, f64, i32, i64 => @as(std.meta.Int(.unsigned, bitsize), @bitCast(value)),
        u32, u64, u8 => @as(u64, value),
        else => @compileError("Invalid type for append_fixed"),
    };

    var index: usize = 0;

    while (index < (bitsize / 8)) : (index += 1) {
        try pb.append(@as(u8, @truncate(as_unsigned_int)));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

/// Appends a submessage to the array.
/// Recursively calls internal_pb_encode.
fn append_submessage(pb: *ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    try internal_pb_encode(pb, value);
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Simple appending of a list of bytes.
fn append_const_bytes(pb: *ArrayList(u8), value: ManagedString) !void {
    const slice = value.getSlice();
    try append_as_varint(pb, slice.len, .Simple);
    try pb.appendSlice(slice);
}

/// simple appending of a list of fixed-size data.
fn append_packed_list_of_fixed(pb: *ArrayList(u8), comptime field: FieldDescriptor, value_list: anytype) !void {
    if (value_list.items.len > 0) {
        // first append the tag for the field descriptor
        try append_tag(pb, field);

        // then write elements
        const len_index = pb.items.len;
        for (value_list.items) |item| {
            try append_fixed(pb, item);
        }

        // and finally prepend the LEN size in the len_index position
        const size_encoded = pb.items.len - len_index;
        try insert_raw_varint(pb, size_encoded, len_index);
    }
}

/// Appends a list of varint to the pb buffer.
fn append_packed_list_of_varint(pb: *ArrayList(u8), value_list: anytype, comptime field: FieldDescriptor, comptime varint_type: VarintType) !void {
    if (value_list.items.len > 0) {
        try append_tag(pb, field);
        const len_index = pb.items.len;
        for (value_list.items) |item| {
            try append_varint(pb, item, varint_type);
        }
        const size_encoded = pb.items.len - len_index;
        try insert_raw_varint(pb, size_encoded, len_index);
    }
}

/// Appends a list of submessages to the pb_buffer. Sequentially, prepending the tag of each message.
fn append_list_of_submessages(pb: *ArrayList(u8), comptime field: FieldDescriptor, value_list: anytype) !void {
    for (value_list.items) |item| {
        try append_tag(pb, field);
        try append_submessage(pb, item);
    }
}

/// Appends a packed list of string to the pb_buffer.
fn append_packed_list_of_strings(pb: *ArrayList(u8), comptime field: FieldDescriptor, value_list: anytype) !void {
    if (value_list.items.len > 0) {
        try append_tag(pb, field);

        const len_index = pb.items.len;
        for (value_list.items) |item| {
            try append_const_bytes(pb, item);
        }
        const size_encoded = pb.items.len - len_index;
        try insert_raw_varint(pb, size_encoded, len_index);
    }
}

/// Appends the full tag of the field in the pb buffer, if there is any.
fn append_tag(pb: *ArrayList(u8), comptime field: FieldDescriptor) !void {
    const tag_value = (field.field_number.? << 3) | field.ftype.get_wirevalue();
    try append_varint(pb, tag_value, .Simple);
}

/// Appends a value to the pb buffer. Starts by appending the tag, then a comptime switch
/// routes the code to the correct type of data to append.
///
/// force_append is set to true if the field needs to be appended regardless of having the default value.
///   it is used when an optional int/bool with value zero need to be encoded. usually value==0 are not written, but optionals
///   require its presence to differentiate 0 from "null"
fn append(pb: *ArrayList(u8), comptime field: FieldDescriptor, value: anytype, comptime force_append: bool) !void {

    // TODO: review semantics of default-value in regards to wire protocol
    const is_default_scalar_value = switch (@typeInfo(@TypeOf(value))) {
        .Optional => value == null,
        // as per protobuf spec, the first element of the enums must be 0 and it is the default value
        .Enum => @intFromEnum(value) == 0,
        else => switch (@TypeOf(value)) {
            bool => value == false,
            i32, u32, i64, u64, f32, f64 => value == 0,
            ManagedString => value.isEmpty(),
            else => false,
        },
    };

    switch (field.ftype) {
        .Varint => |varint_type| {
            if (!is_default_scalar_value or force_append) {
                try append_tag(pb, field);
                try append_varint(pb, value, varint_type);
            }
        },
        .FixedInt => {
            if (!is_default_scalar_value or force_append) {
                try append_tag(pb, field);
                try append_fixed(pb, value);
            }
        },
        .SubMessage => {
            if (!is_default_scalar_value or force_append) {
                try append_tag(pb, field);
                try append_submessage(pb, value);
            }
        },
        .String => {
            if (!is_default_scalar_value or force_append) {
                try append_tag(pb, field);
                try append_const_bytes(pb, value);
            }
        },
        .PackedList => |list_type| {
            switch (list_type) {
                .FixedInt => {
                    try append_packed_list_of_fixed(pb, field, value);
                },
                .Varint => |varint_type| {
                    try append_packed_list_of_varint(pb, value, field, varint_type);
                },
                .String => |varint_type| {
                    // TODO: find examples about how to encode and decode packed strings. the documentation is ambiguous
                    try append_packed_list_of_strings(pb, value, varint_type);
                },
                .SubMessage => @compileError("submessages are not suitable for PackedLists."),
            }
        },
        .List => |list_type| {
            switch (list_type) {
                .FixedInt => {
                    for (value.items) |item| {
                        try append_tag(pb, field);
                        try append_fixed(pb, item);
                    }
                },
                .SubMessage => {
                    try append_list_of_submessages(pb, field, value);
                },
                .String => {
                    for (value.items) |item| {
                        try append_tag(pb, field);
                        try append_const_bytes(pb, item);
                    }
                },
                .Varint => |varint_type| {
                    for (value.items) |item| {
                        try append_tag(pb, field);
                        try append_varint(pb, item, varint_type);
                    }
                },
            }
        },
        .OneOf => |union_type| {
            // iterate over union tags until one matches `active_union_tag` and then use the comptime information to append the value
            const active_union_tag = @tagName(value);
            inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                if (std.mem.eql(u8, union_field.name, active_union_tag)) {
                    try append(pb, @field(union_type._union_desc, union_field.name), @field(value, union_field.name), force_append);
                }
            }
        },
    }
}

/// Internal function that decodes the descriptor information and struct fields
/// before passing them to the append function
fn internal_pb_encode(pb: *ArrayList(u8), data: anytype) !void {
    const field_list = @typeInfo(@TypeOf(data)).Struct.fields;
    const data_type = @TypeOf(data);

    inline for (field_list) |field| {
        if (@typeInfo(field.type) == .Optional) {
            if (@field(data, field.name)) |value| {
                try append(pb, @field(data_type._desc_table, field.name), value, true);
            }
        } else {
            try append(pb, @field(data_type._desc_table, field.name), @field(data, field.name), false);
        }
    }
}

/// Public encoding function, meant to be embdedded in generated structs
pub fn pb_encode(data: anytype, allocator: Allocator) ![]u8 {
    var pb = ArrayList(u8).init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);

    return pb.toOwnedSlice();
}

fn get_field_default_value(comptime for_type: anytype) for_type {
    return switch (@typeInfo(for_type)) {
        .Optional => null,
        // as per protobuf spec, the first element of the enums must be 0 and it is the default value
        .Enum => @as(for_type, @enumFromInt(0)),
        else => switch (for_type) {
            bool => false,
            i32, i64, i8, i16, u8, u32, u64, f32, f64 => 0,
            ManagedString => .Empty,
            else => undefined,
        },
    };
}

/// Generic init function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_init(comptime T: type, allocator: Allocator) T {
    var value: T = undefined;
    inline for (@typeInfo(T).Struct.fields) |field| {
        switch (@field(T._desc_table, field.name).ftype) {
            .String, .Varint, .FixedInt => {
                if (field.default_value) |val| {
                    @field(value, field.name) = @as(*align(1) const field.type, @ptrCast(val)).*;
                } else {
                    @field(value, field.name) = get_field_default_value(field.type);
                }
            },
            .SubMessage => {
                @field(value, field.name) = null;
            },
            .OneOf => {
                @field(value, field.name) = null;
            },
            .List, .PackedList => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
        }
    }

    return value;
}

/// Generic function to deeply duplicate a message using a new allocator.
/// The original parameter is constant
pub fn pb_dupe(comptime T: type, original: T, allocator: Allocator) !T {
    var result: T = undefined;

    inline for (@typeInfo(T).Struct.fields) |field| {
        @field(result, field.name) = try dupe_field(original, field.name, @field(T._desc_table, field.name).ftype, allocator);
    }

    return result;
}

/// Internal deinit function for a specific field
fn dupe_field(original: anytype, comptime field_name: []const u8, comptime ftype: FieldType, allocator: Allocator) !@TypeOf(@field(original, field_name)) {
    switch (ftype) {
        .Varint, .FixedInt => {
            return @field(original, field_name);
        },
        .List => |list_type| {
            var capacity = @field(original, field_name).items.len;
            var list = try @TypeOf(@field(original, field_name)).initCapacity(allocator, capacity);
            if (list_type == .SubMessage or list_type == .String) {
                for (@field(original, field_name).items) |item| {
                    try list.append(try item.dupe(allocator));
                }
            } else {
                for (@field(original, field_name).items) |item| {
                    try list.append(item);
                }
            }
            return list;
        },
        .PackedList => |_| {
            var capacity = @field(original, field_name).items.len;
            var list = try @TypeOf(@field(original, field_name)).initCapacity(allocator, capacity);

            for (@field(original, field_name).items) |item| {
                try list.append(item);
            }

            return list;
        },
        .SubMessage, .String => {
            switch (@typeInfo(@TypeOf(@field(original, field_name)))) {
                .Optional => {
                    if (@field(original, field_name)) |val| {
                        return try val.dupe(allocator);
                    } else {
                        return null;
                    }
                },
                else => return try @field(original, field_name).dupe(allocator),
            }
        },
        .OneOf => |one_of| {
            // if the value is set, inline-iterate over the possible OneOfs
            if (@field(original, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(one_of._union_desc)).Struct.fields) |union_field| {
                    // and if one matches the actual tagName of the union
                    if (std.mem.eql(u8, union_field.name, active)) {
                        // deinit the current value
                        var value = try dupe_field(union_value, union_field.name, @field(one_of._union_desc, union_field.name).ftype, allocator);

                        return @unionInit(one_of, union_field.name, value);
                    }
                }
            }
            return null;
        },
    }
}

/// Generic deinit function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_deinit(data: anytype) void {
    const T = @TypeOf(data);

    inline for (@typeInfo(T).Struct.fields) |field| {
        deinit_field(data, field.name, @field(T._desc_table, field.name).ftype);
    }
}

/// Internal deinit function for a specific field
fn deinit_field(result: anytype, comptime field_name: []const u8, comptime ftype: FieldType) void {
    switch (ftype) {
        .Varint, .FixedInt => {},
        .SubMessage => {
            switch (@typeInfo(@TypeOf(@field(result, field_name)))) {
                .Optional => {
                    if (@field(result, field_name)) |submessage| {
                        submessage.deinit();
                    }
                },
                .Struct => @field(result, field_name).deinit(),
                else => @compileError("unreachable"),
            }
        },
        .List => |list_type| {
            if (list_type == .SubMessage or list_type == .String) {
                for (@field(result, field_name).items) |item| {
                    item.deinit();
                }
            }
            @field(result, field_name).deinit();
        },
        .PackedList => |_| {
            @field(result, field_name).deinit();
        },
        .String => {
            switch (@typeInfo(@TypeOf(@field(result, field_name)))) {
                .Optional => {
                    if (@field(result, field_name)) |str| {
                        str.deinit();
                    }
                },
                else => @field(result, field_name).deinit(),
            }
        },
        .OneOf => |union_type| {
            // if the value is set, inline-iterate over the possible OneOfs
            if (@field(result, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                    // and if one matches the actual tagName of the union
                    if (std.mem.eql(u8, union_field.name, active)) {
                        // deinit the current value
                        deinit_field(union_value, union_field.name, @field(union_type._union_desc, union_field.name).ftype);
                    }
                }
            }
        },
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
/// Please not that "tag" is supposed to be the full tag. See get_full_tag_value.
const Extracted = struct { tag: u32, field_number: u32, data: ExtractedData };

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

fn VarintDecoderIterator(comptime T: type, comptime varint_type: VarintType) type {
    return struct {
        const Self = @This();

        input: []const u8,
        current_index: usize = 0,

        fn next(self: *Self) !?T {
            if (self.current_index < self.input.len) {
                const raw_value = try decode_varint(u64, self.input[self.current_index..]);
                defer self.current_index += raw_value.size;
                return decode_varint_value(T, varint_type, raw_value.value);
            }
            return null;
        }
    };
}

const LengthDelimitedDecoderIterator = struct {
    const Self = @This();

    input: []const u8,
    current_index: usize = 0,

    fn next(self: *Self) !?[]const u8 {
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
            const tag_and_wire = try decode_varint(u32, state.input[state.current_index..]);
            state.current_index += tag_and_wire.size;
            const wire_type = tag_and_wire.value & 0b00000111;
            const data: ExtractedData = switch (wire_type) {
                0 => blk: { // VARINT
                    const varint = try decode_varint(u64, state.input[state.current_index..]);
                    state.current_index += varint.size;
                    break :blk ExtractedData{
                        .RawValue = varint.value,
                    };
                },
                1 => blk: { // 64BIT
                    const value = ExtractedData{ .RawValue = decode_fixed(u64, state.input[state.current_index .. state.current_index + 8]) };
                    state.current_index += 8;
                    break :blk value;
                },
                2 => blk: { // LEN PREFIXED MESSAGE
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
                3, 4 => { // SGROUP,EGROUP
                    return null;
                },
                5 => blk: { // 32BIT
                    const value = ExtractedData{ .RawValue = decode_fixed(u32, state.input[state.current_index .. state.current_index + 4]) };
                    state.current_index += 4;
                    break :blk value;
                },
                else => {
                    return error.InvalidInput;
                },
            };

            return Extracted{ .tag = tag_and_wire.value, .data = data, .field_number = tag_and_wire.value >> 3 };
        } else {
            return null;
        }
    }
};

/// Get a real varint of type T from a raw u64 data.
fn decode_varint_value(comptime T: type, comptime varint_type: VarintType, raw: u64) T {
    return switch (varint_type) {
        .ZigZagOptimized => switch (@typeInfo(T)) {
            .Int => {
                const t = @as(T, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(raw))));
                return @as(T, @intCast((t >> 1) ^ (-(t & 1))));
            },
            .Enum => @as(T, @enumFromInt(@as(i32, @intCast((@as(i64, @intCast(raw)) >> 1) ^ (-(@as(i64, @intCast(raw)) & 1)))))),
            else => @compileError("Invalid type passed"),
        },
        .Simple => switch (@typeInfo(T)) {
            .Int => switch (T) {
                u8, u16, u32, u64 => @as(T, @intCast(raw)),
                i32, i64 => @as(T, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(raw)))),
                else => @compileError("Invalid type " ++ @typeName(T) ++ " passed"),
            },
            .Bool => raw != 0,
            .Enum => @as(T, @enumFromInt(@as(i32, @intCast(raw)))),
            else => @compileError("Invalid type " ++ @typeName(T) ++ " passed"),
        },
    };
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
fn decode_packed_list(slice: []const u8, comptime list_type: ListType, comptime T: type, array: *ArrayList(T), allocator: Allocator) UnionDecodingError!void {
    switch (list_type) {
        .FixedInt => {
            switch (T) {
                u32, i32, u64, i64, f32, f64 => {
                    var fixed_iterator = FixedDecoderIterator(T){ .input = slice };
                    while (fixed_iterator.next()) |value| {
                        try array.append(value);
                    }
                },
                else => @compileError("Type not accepted for FixedInt: " ++ @typeName(T)),
            }
        },
        .Varint => |varint_type| {
            var varint_iterator = VarintDecoderIterator(T, varint_type){ .input = slice };
            while (try varint_iterator.next()) |value| {
                try array.append(value);
            }
        },
        .String => {
            var varint_iterator = LengthDelimitedDecoderIterator{ .input = slice };
            while (try varint_iterator.next()) |value| {
                try array.append(try ManagedString.copy(value, allocator));
            }
        },
        else =>
        // submessages are not suitable for packed lists yet, but the wire message can be malformed
        return error.InvalidInput,
    }
}

/// decode_value receives
fn decode_value(comptime decoded_type: type, comptime ftype: FieldType, extracted_data: Extracted, allocator: Allocator) !decoded_type {
    return switch (ftype) {
        .Varint => |varint_type| switch (extracted_data.data) {
            .RawValue => |value| decode_varint_value(decoded_type, varint_type, value),
            else => error.InvalidInput,
        },
        .FixedInt => switch (extracted_data.data) {
            .RawValue => |value| decode_fixed_value(decoded_type, value),
            else => error.InvalidInput,
        },
        .SubMessage => switch (extracted_data.data) {
            .Slice => |slice| try pb_decode(decoded_type, slice, allocator),
            else => error.InvalidInput,
        },
        .String => switch (extracted_data.data) {
            .Slice => |slice| try ManagedString.copy(slice, allocator),
            else => error.InvalidInput,
        },
        else => {
            std.debug.print("Invalid scalar type {any}\n", .{ftype});
            return error.InvalidInput;
        },
    };
}

fn decode_data(comptime T: type, comptime field_desc: FieldDescriptor, comptime field: StructField, result: *T, extracted_data: Extracted, allocator: Allocator) !void {
    switch (field_desc.ftype) {
        .Varint, .FixedInt, .SubMessage, .String => {
            // first try to release the current value
            deinit_field(result, field.name, field_desc.ftype);

            // then apply the new value
            switch (@typeInfo(field.type)) {
                .Optional => |optional| @field(result, field.name) = try decode_value(optional.child, field_desc.ftype, extracted_data, allocator),
                else => @field(result, field.name) = try decode_value(field.type, field_desc.ftype, extracted_data, allocator),
            }
        },
        .List, .PackedList => |list_type| {
            const child_type = @typeInfo(@TypeOf(@field(result, field.name).items)).Pointer.child;

            switch (list_type) {
                .Varint => |varint_type| {
                    switch (extracted_data.data) {
                        .RawValue => |value| try @field(result, field.name).append(decode_varint_value(child_type, varint_type, value)),
                        .Slice => |slice| try decode_packed_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                    }
                },
                .FixedInt => |_| {
                    switch (extracted_data.data) {
                        .RawValue => |value| try @field(result, field.name).append(decode_fixed_value(child_type, value)),
                        .Slice => |slice| try decode_packed_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                    }
                },
                .SubMessage => switch (extracted_data.data) {
                    .Slice => |slice| {
                        try @field(result, field.name).append(try child_type.decode(slice, allocator));
                    },
                    .RawValue => return error.InvalidInput,
                },
                .String => switch (extracted_data.data) {
                    .Slice => |slice| {
                        try @field(result, field.name).append(try ManagedString.copy(slice, allocator));
                    },
                    .RawValue => return error.InvalidInput,
                },
            }
        },
        .OneOf => |one_of| {
            // the following code:
            // 1. creates a compile time for iterating over all `one_of._union_desc` fields
            // 2. when a match is found, it creates the union value in the `field.name` property of the struct `result`. breaks the for at that point
            const desc_union = one_of._union_desc;
            inline for (@typeInfo(one_of).Union.fields) |union_field| {
                const v = @field(desc_union, union_field.name);
                if (is_tag_known(v, extracted_data)) {
                    // deinit the current value of the enum to prevent leaks
                    deinit_field(result, field.name, field_desc.ftype);

                    // and decode & assign the new value
                    var value = try decode_value(union_field.type, v.ftype, extracted_data, allocator);
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
        const desc_union = field_desc.ftype.OneOf._union_desc;
        inline for (@typeInfo(@TypeOf(desc_union)).Struct.fields) |union_field| {
            if (is_tag_known(@field(desc_union, union_field.name), tag_to_check)) {
                return true;
            }
        }
    }

    return false;
}

/// public decoding function meant to be embedded in message structures
/// Iterates over the input and try to fill the resulting structure accordingly.
pub fn pb_decode(comptime T: type, input: []const u8, allocator: Allocator) !T {
    var result = pb_init(T, allocator);

    var iterator = WireDecoderIterator{ .input = input };

    while (try iterator.next()) |extracted_data| {
        inline for (@typeInfo(T).Struct.fields) |field| {
            const v = @field(T._desc_table, field.name);
            if (is_tag_known(v, extracted_data)) {
                break try decode_data(T, v, field, &result, extracted_data, allocator);
            }
        } else {
            std.debug.print("Unknown field received in {s} {any}\n", .{ @typeName(T), extracted_data });
        }
    }

    return result;
}

pub fn MessageMixins(comptime Self: type) type {
    return struct {
        pub fn encode(self: Self, allocator: Allocator) ![]u8 {
            return pb_encode(self, allocator);
        }
        pub fn decode(input: []const u8, allocator: Allocator) UnionDecodingError!Self {
            return pb_decode(Self, input, allocator);
        }
        pub fn init(allocator: Allocator) Self {
            return pb_init(Self, allocator);
        }
        pub fn deinit(self: Self) void {
            return pb_deinit(self);
        }
        pub fn dupe(self: Self, allocator: Allocator) !Self {
            return pb_dupe(Self, self, allocator);
        }
    };
}

test "get varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();
    try append_varint(&pb, @as(i32, 0x12c), .Simple);
    try append_varint(&pb, @as(i32, 0x0), .Simple);
    try append_varint(&pb, @as(i32, 0x1), .Simple);
    try append_varint(&pb, @as(i32, 0xA1), .Simple);
    try append_varint(&pb, @as(i32, 0xFF), .Simple);

    try testing.expectEqualSlices(u8, &[_]u8{ 0b10101100, 0b00000010, 0x0, 0x1, 0xA1, 0x1, 0xFF, 0x01 }, pb.items);
}

test "append_raw_varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();

    try append_raw_varint(&pb, 3);

    try testing.expectEqualSlices(u8, &[_]u8{0x03}, pb.items);
    try append_raw_varint(&pb, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1 }, pb.items);
    try append_raw_varint(&pb, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1, 0x0 }, pb.items);
    try append_raw_varint(&pb, 0x80);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x3, 0x1, 0x0, 0x80, 0x1 }, pb.items);
    try append_raw_varint(&pb, 0xffffffff);
    try testing.expectEqualSlices(u8, &[_]u8{
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
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();
    const list = &[_]u64{ 0, 1, 2, 3, 199, 0xff, 0xfa, 1231313, 999288361, 0, 0xfffffff, 0x80808080, 0xffffffff };

    for (list) |num|
        try append_varint(&pb, num, .Simple);

    var demo = VarintDecoderIterator(u64, .Simple){ .input = pb.items };

    for (list) |num|
        try testing.expectEqual(num, (try demo.next()).?);

    try testing.expectEqual(demo.next(), null);
}

test "VarintDecoderIterator" {
    var demo = VarintDecoderIterator(u64, .Simple){ .input = "\x01\x02\x03\x04\xA1\x01" };
    try testing.expectEqual(demo.next(), 1);
    try testing.expectEqual(demo.next(), 2);
    try testing.expectEqual(demo.next(), 3);
    try testing.expectEqual(demo.next(), 4);
    try testing.expectEqual(demo.next(), 0xA1);
    try testing.expectEqual(demo.next(), null);
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

test "FixedDecoderIterator" {
    var demo = FixedDecoderIterator(i64){ .input = &[_]u8{ 133, 255, 255, 255, 255, 255, 255, 255 } };
    try testing.expectEqual(demo.next(), -123);
    try testing.expectEqual(demo.next(), null);
}

// length delimited message including a list of varints
test "unit varint packed - decode - multi-byte-varint" {
    const bytes = &[_]u8{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
    var list = ArrayList(u32).init(testing.allocator);
    defer list.deinit();

    try decode_packed_list(bytes, .{ .Varint = .Simple }, u32, &list, testing.allocator);

    try testing.expectEqualSlices(u32, &[_]u32{ 3, 270, 86942 }, list.items);
}

test "decode fixed" {
    const u_32 = [_]u8{ 2, 0, 0, 0 };
    const u_32_result: u32 = 2;
    try testing.expectEqual(u_32_result, decode_fixed(u32, &u_32));

    const u_64 = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const u_64_result: u64 = 1;
    try testing.expectEqual(u_64_result, decode_fixed(u64, &u_64));

    const i_32 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const i_32_result: i32 = -1;
    try testing.expectEqual(i_32_result, decode_fixed(i32, &i_32));

    const i_64 = [_]u8{ 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const i_64_result: i64 = -2;
    try testing.expectEqual(i_64_result, decode_fixed(i64, &i_64));

    const f_32 = [_]u8{ 0x00, 0x00, 0xa0, 0x40 };
    const f_32_result: f32 = 5.0;
    try testing.expectEqual(f_32_result, decode_fixed(f32, &f_32));

    const f_64 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x40 };
    const f_64_result: f64 = 5.0;
    try testing.expectEqual(f_64_result, decode_fixed(f64, &f_64));
}

test "zigzag i32 - encode" {
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();

    const input = "\xE7\x07";

    // -500 (.ZigZag)  encodes to {0xE7,0x07} which equals to 999 (.Simple)

    try append_as_varint(&pb, @as(i32, -500), .ZigZagOptimized);
    try testing.expectEqualSlices(u8, input, pb.items);
}

test "zigzag i32/i64 - decode" {
    try testing.expectEqual(@as(i32, 1), decode_varint_value(i32, .ZigZagOptimized, 2));
    try testing.expectEqual(@as(i32, -2), decode_varint_value(i32, .ZigZagOptimized, 3));
    try testing.expectEqual(@as(i32, -500), decode_varint_value(i32, .ZigZagOptimized, 999));
    try testing.expectEqual(@as(i64, -500), decode_varint_value(i64, .ZigZagOptimized, 999));
    try testing.expectEqual(@as(i64, -500), decode_varint_value(i64, .ZigZagOptimized, 999));
    try testing.expectEqual(@as(i64, -0x80000000), decode_varint_value(i64, .ZigZagOptimized, 0xffffffff));
}

test "zigzag i64 - encode" {
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();

    const input = "\xE7\x07";

    // -500 (.ZigZag)  encodes to {0xE7,0x07} which equals to 999 (.Simple)

    try append_as_varint(&pb, @as(i64, -500), .ZigZagOptimized);
    try testing.expectEqualSlices(u8, input, pb.items);
}
