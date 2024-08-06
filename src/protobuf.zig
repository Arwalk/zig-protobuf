const std = @import("std");
const StructField = std.builtin.Type.StructField;
const isIntegral = std.meta.trait.isIntegral;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json = std.json;
const base64 = std.base64;
const base64Errors = std.base64.Error;
const ParseFromValueError = std.json.ParseFromValueError;

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

    // This method is used by std.json
    // internally for deserialization. DO NOT RENAME!
    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: json.ParseOptions,
    ) !ManagedString {
        const string = try json.innerParse([]const u8, allocator, source, options);
        return ManagedString.copy(string, allocator);
    }

    // This method is used by std.json
    // internally for serialization. DO NOT RENAME!
    pub fn jsonStringify(self: *const ManagedString, jws: anytype) !void {
        try jws.write(self.getSlice());
    }
};

/// Enum describing the different field types available.
pub const FieldTypeTag = enum { Varint, FixedInt, SubMessage, String, Bytes, List, PackedList, OneOf };

/// Enum describing how much bits a FixedInt will use.
pub const FixedSize = enum(u3) { I64 = 1, I32 = 5 };

/// Enum describing the content type of a repeated field.
pub const ListTypeTag = enum {
    Varint,
    String,
    Bytes,
    FixedInt,
    SubMessage,
};

/// Tagged union for repeated fields, giving the details of the underlying type.
pub const ListType = union(ListTypeTag) {
    Varint: VarintType,
    String,
    Bytes,
    FixedInt: FixedSize,
    SubMessage,
};

/// Main tagged union holding the details of any field type.
pub const FieldType = union(FieldTypeTag) {
    Varint: VarintType,
    FixedInt: FixedSize,
    SubMessage,
    String,
    Bytes,
    List: ListType,
    PackedList: ListType,
    OneOf: type,

    /// returns the wire type of a field. see https://developers.google.com/protocol-buffers/docs/encoding#structure
    pub fn get_wirevalue(comptime ftype: FieldType) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => |size| @intFromEnum(size),
            .String, .SubMessage, .PackedList, .Bytes => 2,
            .List => |inner| switch (inner) {
                .Varint => 0,
                .FixedInt => |size| @intFromEnum(size),
                .String, .SubMessage, .Bytes => 2,
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
        if (@typeInfo(type_of_val).Int.signedness == .signed) {
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
        .String, .Bytes => {
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
                .String, .Bytes => |varint_type| {
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
                .String, .Bytes => {
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
            .String, .Varint, .FixedInt, .Bytes => {
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

/// Internal dupe function for a specific field
fn dupe_field(original: anytype, comptime field_name: []const u8, comptime ftype: FieldType, allocator: Allocator) !@TypeOf(@field(original, field_name)) {
    switch (ftype) {
        .Varint, .FixedInt => {
            return @field(original, field_name);
        },
        .List => |list_type| {
            const capacity = @field(original, field_name).items.len;
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
            const capacity = @field(original, field_name).items.len;
            var list = try @TypeOf(@field(original, field_name)).initCapacity(allocator, capacity);

            for (@field(original, field_name).items) |item| {
                try list.append(item);
            }

            return list;
        },
        .SubMessage, .String, .Bytes => {
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
                        const value = try dupe_field(union_value, union_field.name, @field(one_of._union_desc, union_field.name).ftype, allocator);

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
        .String, .Bytes => {
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
        .String, .Bytes => switch (extracted_data.data) {
            .Slice => |slice| try ManagedString.copy(slice, allocator),
            else => error.InvalidInput,
        },
        .List, .PackedList, .OneOf => {
            std.log.warn("Invalid scalar type {any}\n", .{ftype});
            return error.InvalidInput;
        },
    };
}

fn decode_data(comptime T: type, comptime field_desc: FieldDescriptor, comptime field: StructField, result: *T, extracted_data: Extracted, allocator: Allocator) !void {
    switch (field_desc.ftype) {
        .Varint, .FixedInt, .SubMessage, .String, .Bytes => {
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
                .String, .Bytes => switch (extracted_data.data) {
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
            std.log.warn("Unknown field received in {s} {any}\n", .{ @typeName(T), extracted_data });
        }
    }

    return result;
}

fn freeAllocated(allocator: Allocator, token: json.Token) void {
    // Took from std.json source code since it was non-public one
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

fn fillDefaultStructValues(
    comptime T: type,
    r: *T,
    fields_seen: *[@typeInfo(T).Struct.fields.len]bool,
) !void {
    // Took from std.json source code since it was non-public one
    inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.default_value) |default_ptr| {
                const default = @as(
                    *align(1) const field.type,
                    @ptrCast(default_ptr),
                ).*;
                @field(r, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
    }
}

fn base64ErrorToJsonParseError(err: base64Errors) ParseFromValueError {
    return switch (err) {
        base64Errors.NoSpaceLeft => ParseFromValueError.Overflow,
        base64Errors.InvalidPadding, base64Errors.InvalidCharacter => ParseFromValueError.UnexpectedToken,
    };
}

fn parse_bytes(
    allocator: Allocator,
    source: anytype,
    options: json.ParseOptions,
) !ManagedString {
    const temp_raw = try json.innerParse([]u8, allocator, source, options);
    const size = base64.standard.Decoder.calcSizeForSlice(temp_raw) catch |err| {
        return base64ErrorToJsonParseError(err);
    };
    const tempstring = try allocator.alloc(u8, size);
    errdefer allocator.free(tempstring);
    base64.standard.Decoder.decode(tempstring, temp_raw) catch |err| {
        return base64ErrorToJsonParseError(err);
    };
    return ManagedString.move(tempstring, allocator);
}

fn parseStructField(
    comptime T: type,
    result: *T,
    comptime fieldInfo: StructField,
    allocator: Allocator,
    source: anytype,
    options: json.ParseOptions,
) !void {
    @field(result.*, fieldInfo.name) = switch (@field(
        T._desc_table,
        fieldInfo.name,
    ).ftype) {
        .List, .PackedList => |list_type| list: {
            // repeated T -> ArrayList(T)
            switch (try source.peekNextTokenType()) {
                .array_begin => {
                    assert(.array_begin == try source.next());
                    const child_type = @typeInfo(
                        fieldInfo.type.Slice,
                    ).Pointer.child;
                    var array_list = ArrayList(child_type).init(allocator);
                    while (true) {
                        if (.array_end == try source.peekNextTokenType()) {
                            _ = try source.next();
                            break;
                        }
                        try array_list.ensureUnusedCapacity(1);
                        array_list.appendAssumeCapacity(switch (list_type) {
                            .Bytes => try parse_bytes(allocator, source, options),
                            .Varint, .FixedInt, .SubMessage, .String => other: {
                                break :other try json.innerParse(
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
        .OneOf => |oneof| oneof: {
            // oneof -> union
            var union_value: switch (@typeInfo(
                @TypeOf(@field(result.*, fieldInfo.name)),
            )) {
                .Union => @TypeOf(@field(result.*, fieldInfo.name)),
                .Optional => |optional| optional.child,
                else => unreachable,
            } = undefined;

            const union_type = @TypeOf(union_value);
            const union_info = @typeInfo(union_type).Union;
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
                            oneof._union_desc,
                            union_field.name,
                        ).ftype) {
                            .Bytes => bytes: {
                                break :bytes try parse_bytes(
                                    allocator,
                                    source,
                                    options,
                                );
                            },
                            .Varint, .FixedInt, .SubMessage, .String => other: {
                                break :other try json.innerParse(
                                    union_field.type,
                                    allocator,
                                    source,
                                    options,
                                );
                            },
                            .List, .PackedList => {
                                @compileError("Repeated fields are not allowed in oneof");
                            },
                            .OneOf => {
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
        .Bytes => bytes: {
            // "bytes" -> ManagedString
            break :bytes try parse_bytes(allocator, source, options);
        },
        .Varint, .FixedInt, .SubMessage, .String => other: {
            // .SubMessage's (generated structs) and .String's
            //   (ManagedString's) have its own jsonParse implementation
            // Numeric types will be handled using default std.json parser
            break :other try json.innerParse(
                fieldInfo.type,
                allocator,
                source,
                options,
            );
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

pub fn pb_json_decode(
    comptime T: type,
    input: []const u8,
    options: json.ParseOptions,
    allocator: Allocator,
) !std.json.Parsed(T) {
    const parsed = try json.parseFromSlice(T, allocator, input, options);
    return parsed;
}

pub fn pb_json_encode(
    data: anytype,
    options: json.StringifyOptions,
    allocator: Allocator,
) ![]u8 {
    return try json.stringifyAlloc(allocator, data, options);
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

    if (comptime std.ascii.isUpper(camel_cased_string[0])) {
        camel_cased_string[0] = std.ascii.toLower(camel_cased_string[0]);
    }

    return camel_cased_string;
}

fn print_numeric(value: anytype, jws: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .Float, .ComptimeFloat => {},
        .Int, .ComptimeInt, .Enum, .Bool => {
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
    const size = base64.standard.Encoder.calcSize(
        value.getSlice().len,
    );

    try jsonValueStartAssumeTypeOk(jws);
    try jws.stream.writeByte('"');

    var innerArrayList: *ArrayList(u8) = jws.stream.context;
    try innerArrayList.ensureTotalCapacity(innerArrayList.capacity + size + 1);
    const temp = innerArrayList.unusedCapacitySlice();
    _ = base64.standard.Encoder.encode(
        temp,
        value.getSlice(),
    );
    innerArrayList.items.len += size;
    try jws.stream.writeByte('"');

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
    try jws.stream.writeByte('\n');
    try jws.stream.writeByteNTimes(char, n_chars);
}

const assert = std.debug.assert;

fn jsonIsComplete(jws: anytype) bool {
    return jws.indent_level == 0 and jws.next_punctuation == .comma;
}

fn jsonValueStartAssumeTypeOk(jws: anytype) !void {
    assert(!jsonIsComplete(jws));
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
            try jws.stream.writeByte(',');
            try jsonIndent(jws);
        },
        .colon => {
            try jws.stream.writeByte(':');
            if (jws.options.whitespace != .minified) {
                try jws.stream.writeByte(' ');
            }
        },
    }
}

fn stringify_struct_field(
    struct_field: anytype,
    field_descriptor: FieldDescriptor,
    jws: anytype,
) !void {
    var value: switch (@typeInfo(@TypeOf(struct_field))) {
        .Optional => |optional| optional.child,
        else => @TypeOf(struct_field),
    } = undefined;

    switch (@typeInfo(@TypeOf(struct_field))) {
        .Optional => {
            if (struct_field) |v| {
                value = v;
            } else return;
        },
        else => {
            value = struct_field;
        },
    }

    switch (field_descriptor.ftype) {
        .Bytes => {
            // ManagedString representing protobuf's "bytes" type
            try print_bytes(value, jws);
        },
        .List, .PackedList => |list_type| {
            // ArrayList
            const slice = value.items;
            try jws.beginArray();
            for (slice) |el| {
                switch (list_type) {
                    .Varint, .FixedInt => {
                        try print_numeric(el, jws);
                    },
                    .Bytes => {
                        try print_bytes(el, jws);
                    },
                    .String, .SubMessage => {
                        try jws.write(el);
                    },
                }
            }
            try jws.endArray();
        },
        .OneOf => |oneof| {
            // Tagged union type
            const union_info = @typeInfo(@TypeOf(value)).Union;
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
                    switch (@field(oneof._union_desc, union_field.name).ftype) {
                        .Varint, .FixedInt => {
                            try print_numeric(@field(value, union_field.name), jws);
                        },
                        .Bytes => {
                            try print_bytes(@field(value, union_field.name), jws);
                        },
                        .String, .SubMessage => {
                            try jws.write(@field(value, union_field.name));
                        },
                        .List, .PackedList => {
                            @compileError("Repeated fields are not allowed in oneof");
                        },
                        .OneOf => {
                            @compileError("one oneof inside another? really?");
                        },
                    }
                    break;
                }
            } else unreachable;

            try jws.endObject();
        },
        .Varint, .FixedInt => {
            try print_numeric(value, jws);
        },
        .SubMessage, .String => {
            // .SubMessage's (generated structs) and .String's
            //   (ManagedString's) have its own jsonStringify implementation
            // Numeric types will be handled using default std.json parser
            try jws.write(value);
        },
        // NOTE: You better not to use *else* here, see todo comment
        //   at the end of parseStructField function above
    }
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
        pub fn json_decode(
            input: []const u8,
            options: json.ParseOptions,
            allocator: Allocator,
        ) !std.json.Parsed(Self) {
            return pb_json_decode(Self, input, options, allocator);
        }
        pub fn json_encode(
            self: Self,
            options: json.StringifyOptions,
            allocator: Allocator,
        ) ![]const u8 {
            return pb_json_encode(self, options, allocator);
        }

        // This method is used by std.json
        // internally for deserialization. DO NOT RENAME!
        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: json.ParseOptions,
        ) !Self {
            if (.object_begin != try source.next()) {
                return error.UnexpectedToken;
            }

            // Mainly taken from 0.13.0's source code
            var result: Self = undefined;
            const structInfo = @typeInfo(Self).Struct;
            var fields_seen = [_]bool{false} ** structInfo.fields.len;

            while (true) {
                var name_token: ?json.Token = try source.nextAllocMax(
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
                    // Didn't match anything.
                    freeAllocated(allocator, name_token.?);
                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                    } else {
                        return error.UnknownField;
                    }
                }
            }
            try fillDefaultStructValues(Self, &result, &fields_seen);
            return result;
        }

        // This method is used by std.json
        // internally for serialization. DO NOT RENAME!
        pub fn jsonStringify(self: *const Self, jws: anytype) !void {
            try jws.beginObject();

            inline for (@typeInfo(Self).Struct.fields) |fieldInfo| {
                const camel_case_name = comptime to_camel_case(fieldInfo.name);

                if (switch (@typeInfo(fieldInfo.type)) {
                    .Optional => @field(self, fieldInfo.name) != null,
                    else => true,
                }) try jws.objectField(camel_case_name);

                try stringify_struct_field(
                    @field(self, fieldInfo.name),
                    @field(Self._desc_table, fieldInfo.name),
                    jws,
                );
            }

            try jws.endObject();
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
