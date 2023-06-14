const std = @import("std");
const StructField = std.builtin.Type.StructField;
const isSignedInt = std.meta.trait.isSignedInt;
const isIntegral = std.meta.trait.isIntegral;
const Allocator = std.mem.Allocator;

// common definitions

const ArrayList = std.ArrayList;

/// Type of encoding for a Varint value.
const VarintType = enum { Simple, ZigZagOptimized };

const DecodingError = error{ NotEnoughData, InvalidInput };

const UnionDecodingError = DecodingError || Allocator.Error;

/// Enum describing the different field types available.
pub const FieldTypeTag = enum { Varint, FixedInt, SubMessage, List, PackedList, String, OneOf, Map };

pub const TagNumber = enum(u32) { VARINT = 0, I64 = 1, LEN = 2, SGROUP = 3, EGROUP = 4, I32 = 5 };

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
    FixedInt: TagNumber,
    SubMessage,
};

/// Enum describing the details of keys or values for a map type.
pub const KeyValueTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
    List,
};

/// Tagged union giving the details of underlying types in a map field
pub const KeyValueType = union(KeyValueTypeTag) {
    Varint: VarintType,
    FixedInt,
    SubMessage,
    List: ListType,

    pub fn toFieldType(comptime self: KeyValueType) FieldType {
        return comptime switch (self) {
            .Varint => |varint_type| .{ .Varint = varint_type },
            .FixedInt => .{.FixedInt},
            .SubMessage => .{.SubMessage},
            .List => |list_type| .{ .List = list_type },
            .PackedList => |list_type| .{ .PackedList = list_type },
        };
    }
};

/// Struct for key and values of a map type
pub const KeyValueTypeData = struct {
    t: type,
    pb_data: KeyValueType,
};

/// Struct describing keys and values of a map
pub const MapData = struct { key: KeyValueTypeData, value: KeyValueTypeData };

/// Main tagged union holding the details of any field type.
pub const FieldType = union(FieldTypeTag) {
    Varint: VarintType,
    FixedInt: TagNumber,
    SubMessage,
    String,
    List: ListType,
    PackedList: ListType,
    OneOf: type,
    Map: MapData,

    /// returns the wire type of a field. see https://developers.google.com/protocol-buffers/docs/encoding#structure
    pub fn get_wirevalue(comptime ftype: FieldType) u3 {
        comptime {
            switch (ftype) {
                .OneOf => @compileError("Shouldn't pass a .OneOf field to this function here."),
                else => {},
            }
        }
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => |size| switch (size) {
                .I32 => 5,
                .I64 => 1,
                else => @compileError("Type " ++ @typeName(ftype) ++ "not compatible with fixed int"),
            },
            .String, .SubMessage, .PackedList, .Map => 2,
            .List => |inner| switch (inner) {
                .Varint => 0,
                .FixedInt => |size| switch (size) {
                    .I32 => 5,
                    .I64 => 1,
                    else => @compileError("Type " ++ @typeName(ftype) ++ "not compatible with fixed int"),
                },
                .String, .SubMessage => 2,
            },
            .OneOf => unreachable,
        };
    }
};

/// Structure describing a field. Most of the relevant informations are
/// In the FieldType data. Tag is optional as OneOf fields are "virtual" fields.
pub const FieldDescriptor = struct {
    field_number: ?u32,
    tag: ?u32,
    ftype: FieldType,
};

/// Helper function to build a FieldDescriptor. Makes code clearer, mostly.
pub fn fd(comptime field_number: ?u32, comptime ftype: FieldType) FieldDescriptor {
    // calculates the comptime value of (tag_index << 3) + wire type.
    // This is fully calculated at comptime which is great.
    const tag: ?u32 = if (field_number) |num| ((num << 3) | ftype.get_wirevalue()) else null;

    return FieldDescriptor{ .field_number = field_number, .ftype = ftype, .tag = tag };
}

// encoding

/// Appends an unsigned varint value.
/// Awaits a u64 value as it's the biggest unsigned varint possible,
// so anything can be cast to it by definition
fn append_raw_varint(pb: *ArrayList(u8), value: u64) !void {
    var copy = value;
    while (copy > 0x7F) {
        try pb.append(0x80 + @intCast(u8, copy & 0x7F));
        copy = copy >> 7;
    }
    try pb.append(@intCast(u8, copy & 0x7F));
}

/// Inserts a varint into the pb at start_index
/// Mostly useful when inserting the size of a field after it has been
/// Appended to the pb buffer.
fn insert_raw_varint(pb: *ArrayList(u8), size: u64, start_index: usize) !void {
    if (size < 0x7F) {
        try pb.insert(start_index, @truncate(u8, size));
    } else {
        var copy = size;
        var index = start_index;
        while (copy > 0x7F) : (index += 1) {
            try pb.insert(index, 0x80 + @intCast(u8, copy & 0x7F));
            copy = copy >> 7;
        }
        try pb.insert(index, @intCast(u8, copy & 0x7F));
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
                    break :blk @intCast(u64, (int >> (bitsize - 1)) ^ (int << 1));
                },
                .Simple => {
                    break :blk @bitCast(std.meta.Int(.unsigned, bitsize), int);
                },
            }
        } else {
            break :blk @intCast(u64, int);
        }
    };

    try append_raw_varint(pb, val);
}

/// Append a value of any complex type that can be transfered as a varint
/// Only serves as an indirection to manage Enum and Booleans properly.
fn append_varint(pb: *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @as(i32, @enumToInt(value)), varint_type),
        .Bool => try append_as_varint(pb, @as(u8, if (value) 1 else 0), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

/// Appends a fixed size int to the pb buffer.
/// Takes care of casting any signed/float value to an appropriate unsigned type
fn append_fixed(pb: *ArrayList(u8), value: anytype) !void {
    comptime {
        switch (@TypeOf(value)) {
            f32, f64, i32, i64, u32, u64, u8 => {},
            else => @compileError("Invalid type for append_fixed"),
        }
    }

    const bitsize = @bitSizeOf(@TypeOf(value));

    var as_unsigned_int = switch (@TypeOf(value)) {
        f32, f64, i32, i64 => @bitCast(std.meta.Int(.unsigned, bitsize), value),
        u32, u64, u8 => @as(u64, value),
        else => unreachable,
    };

    var index: usize = 0;

    while (index < (bitsize / 8)) : (index += 1) {
        try pb.append(@truncate(u8, as_unsigned_int));
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
fn append_bytes(pb: *ArrayList(u8), value: *const ArrayList(u8)) !void {
    try append_as_varint(pb, value.len, .Simple);
    try pb.appendSlice(value.items);
}

/// Simple appending of a list of bytes.
fn append_const_bytes(pb: *ArrayList(u8), value: []const u8) !void {
    try append_as_varint(pb, value.len, .Simple);
    try pb.appendSlice(value);
}

/// simple appending of a list of fixed-size data.
fn append_packed_list_of_fixed(pb: *ArrayList(u8), comptime field: FieldDescriptor, value: anytype) !void {
    // first append the tag for the field descriptor
    try append_tag(pb, field);

    // then write elements
    const len_index = pb.items.len;
    for (value.items) |item| {
        try append_fixed(pb, item);
    }

    // and finally prepend the LEN size in the len_index position
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Appends a list of varint to the pb buffer.
fn append_packed_list_of_varint(pb: *ArrayList(u8), value_list: anytype, comptime field: FieldDescriptor, comptime varint_type: VarintType) !void {
    try append_tag(pb, field);
    const len_index = pb.items.len;
    for (value_list.items) |item| {
        try append_varint(pb, item, varint_type);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
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
    try append_tag(pb, field);

    const len_index = pb.items.len;
    for (value_list.items) |item| {
        try append_const_bytes(pb, item);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Appends the full tag of the field in the pb buffer, if there is any.
fn append_tag(pb: *ArrayList(u8), comptime field: FieldDescriptor) !void {
    if (field.tag) |tag_value| {
        try append_varint(pb, tag_value, .Simple);
    }
}

fn MapSubmessage(comptime key_data: KeyValueTypeData, comptime value_data: KeyValueTypeData) type {
    return struct {
        const Self = @This();

        key: ?key_data.t,
        value: ?value_data.t,

        pub const _desc_table = .{ .key = fd(1, key_data.pb_data.toFieldType()), .value = fd(2, value_data.pb_data.toFieldType()) };

        pub fn encode(self: Self, allocator: Allocator) ![]u8 {
            return pb_encode(self, allocator);
        }

        pub fn decode(input: []const u8, allocator: Allocator) !Self {
            return pb_decode(Self, input, allocator);
        }

        pub fn init(allocator: Allocator) Self {
            return pb_init(Self, allocator);
        }

        pub fn deinit(self: Self) void {
            pb_deinit(self);
        }
    };
}

fn get_map_submessage_type(comptime map_data: MapData) type {
    return MapSubmessage(map_data.key, map_data.value);
}

/// Appends the content of a Map field to the pb buffer.
/// Relies on a property of maps being basically a list of submessage with key index = 1 and value index = 2
/// By relying on this property, encoding maps is as easy as building an internal
/// Struct type with this data, and encoding using all the rest of the tool already
/// at hand.
/// See this note for details https://developers.google.com/protocol-buffers/docs/proto3#backwards_compatibility
fn append_map(pb: *ArrayList(u8), comptime field: FieldDescriptor, map: anytype) !void {
    const len_index = pb.items.len;
    var iterator: @TypeOf(map).Iterator = map.iterator();

    const Submessage = get_map_submessage_type(field.ftype.Map);
    while (iterator.next()) |data| {
        try append_submessage(pb, Submessage{ .key = data.key_ptr.*, .value = data.value_ptr.* });
    }

    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Appends a value to the pb buffer. Starts by appending the tag, then a comptime switch
/// routes the code to the correct type of data to append.
fn append(pb: *ArrayList(u8), comptime field: FieldDescriptor, value: anytype) !void {
    switch (field.ftype) {
        .Varint => |varint_type| {
            try append_tag(pb, field);
            try append_varint(pb, value, varint_type);
        },
        .FixedInt => {
            try append_tag(pb, field);
            try append_fixed(pb, value);
        },
        .SubMessage => {
            try append_tag(pb, field);
            try append_submessage(pb, value);
        },
        .String => {
            try append_tag(pb, field);
            try append_const_bytes(pb, value);
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
                    try append_packed_list_of_strings(pb, value, varint_type);
                },
                .SubMessage => {
                    // submessages are not suitable for PackedLists
                    return error.InvalidInput;
                },
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
            const active = @tagName(value);
            inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                if (std.mem.eql(u8, union_field.name, active)) {
                    try append(pb, @field(union_type._union_desc, union_field.name), @field(value, union_field.name));
                }
            }
        },
        .Map => {
            try append_map(pb, field, value);
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
                try append(pb, @field(data_type._desc_table, field.name), value);
            }
        } else {
            switch (@field(data_type._desc_table, field.name).ftype) {
                .List, .PackedList => if (@field(data, field.name).items.len != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @field(data, field.name));
                },
                .Map => if (@field(data, field.name).count() != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @field(data, field.name));
                },
                .Varint, .FixedInt => if (@as(u64, @field(data, field.name)) != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @field(data, field.name));
                },
                .String => if (@field(data, field.name).len != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @field(data, field.name));
                },
                else => @compileLog(@typeName(field.type)),
            }
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

/// Generic init function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_init(comptime T: type, allocator: Allocator) T {
    var value: T = undefined;
    inline for (@typeInfo(T).Struct.fields) |field| {
        switch (@field(T._desc_table, field.name).ftype) {
            .Varint, .FixedInt, .SubMessage => {
                @field(value, field.name) = if (field.default_value) |val|
                    @ptrCast(*align(1) const field.type, val).*
                else switch (field.type) {
                    bool => false,
                    i32, i64, i8, i16, u8, u32, u64 => 0,
                    else => null,
                };
            },
            .String => {
                @field(value, field.name) = null;
            },
            .List, .Map, .PackedList => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
            .OneOf => {
                @field(value, field.name) = null;
            },
        }
    }

    return value;
}

/// Generic deinit function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_deinit(data: anytype) void {
    const T = @TypeOf(data);

    inline for (@typeInfo(T).Struct.fields) |field| {
        deinit_field(data, field.name, @field(T._desc_table, field.name).ftype);
    }
}

/// Internal deinit function for a specific field
fn deinit_field(field: anytype, comptime field_name: []const u8, comptime ftype: FieldType) void {
    switch (ftype) {
        .Varint, .FixedInt => {},
        .SubMessage => {
            if (@field(field, field_name)) |submessage| {
                submessage.deinit();
            }
        },
        .List => |list_type| {
            if (list_type == .SubMessage) {
                for (@field(field, field_name).items) |item| {
                    item.deinit();
                }
            }
            @field(field, field_name).deinit();
        },
        .PackedList => |_| {
            @field(field, field_name).deinit();
        },
        .String => {
            // nothing?
        },
        .OneOf => |union_type| {
            if (@field(field, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                    if (std.mem.eql(u8, union_field.name, active)) {
                        deinit_field(union_value, union_field.name, @field(union_type._union_desc, union_field.name).ftype);
                    }
                }
            }
        },
        .Map => |_| {
            // for unknown reason i have to specifically made it var here. Otherwise it's a const field.
            var temp = @field(field, field_name); // key/values requiring dealloc aren't managed yet!
            temp.deinit();
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
        value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), shift));
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
        result += @intCast(result_base, byte) << (@intCast(std.math.Log2Int(result_base), index * 8));
    }

    return switch (T) {
        u32, u64 => result,
        else => @bitCast(T, result),
    };
}

/// Decodes a fixed value to type T
fn decode_fixed_raw(comptime T: type, value: u64) T {
    return switch (T) {
        f32, u32, i32 => @bitCast(T, @intCast(u32, value)),
        bool => value != 0,
        else => @bitCast(T, value),
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
                return get_varint_value(T, varint_type, raw_value.value);
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
fn get_varint_value(comptime T: type, comptime varint_type: VarintType, raw: u64) T {
    return switch (varint_type) {
        .ZigZagOptimized => switch (@typeInfo(T)) {
            .Int => @intCast(T, (@intCast(T, raw) >> 1) ^ (-(@intCast(T, raw) & 1))),
            .Enum => @intToEnum(T, @intCast(i32, (@intCast(i64, raw) >> 1) ^ (-(@intCast(i64, raw) & 1)))),
            else => @compileError("Invalid type passed"),
        },
        .Simple => switch (@typeInfo(T)) {
            .Int => switch (T) {
                u8, u16, u32, u64 => @intCast(T, raw),
                i32, i64 => @bitCast(T, @truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)),
                else => @compileError("Invalid type " ++ @typeName(T) ++ " passed"),
            },
            .Bool => raw != 0,
            .Enum => @intToEnum(T, @intCast(i32, raw)),
            else => @compileError("Invalid type " ++ @typeName(T) ++ " passed"),
        },
    };
}

/// Get a real fixed value of type T from a raw u64 value.
fn get_fixed_value(comptime T: type, raw: u64) T {
    return switch (T) {
        i32, u32, f32 => @bitCast(T, @truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)),
        i64, f64, u64 => @bitCast(T, raw),
        else => @compileError("Invalid type for get_fixed_value"),
    };
}

fn decode_list(input: []const u8, comptime list_type: ListType, comptime T: type, array: *ArrayList(T), allocator: Allocator) UnionDecodingError!void {
    switch (list_type) {
        .FixedInt => {
            switch (T) {
                u32, i32, u64, i64, f32, f64 => {
                    var fixed_iterator = FixedDecoderIterator(T){ .input = input };
                    while (fixed_iterator.next()) |value| {
                        try array.append(value);
                    }
                    @panic("needs tests");
                },
                else => @compileError("Type not accepted for FixedInt: " ++ @typeName(T)),
            }
        },
        .Varint => |varint_type| {
            var varint_iterator = VarintDecoderIterator(T, varint_type){ .input = input };
            while (varint_iterator.next()) |value| {
                try array.append(value);
            }
        },
        .SubMessage => {
            try array.append(try T.decode(input, allocator));
        },
        .String => {
            try array.append(input);
        },
    }
}

/// this function receives a slice of a message and decodes one by one the elements of the packet list until the slice is exhausted
fn decode_packed_list(slice: []const u8, comptime list_type: ListType, comptime T: type, array: *ArrayList(T)) UnionDecodingError!void {
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
                try array.append(value);
            }
        },
        .SubMessage => return error.InvalidInput, // submessages are not suitable for packed lists yet
    }
}

fn set_value(comptime T: type, comptime int_type: type, comptime fieldName: []const u8, result: *T, comptime ftype: FieldType, extracted_data: Extracted, allocator: Allocator) !void {
    @field(result, fieldName) = switch (ftype) {
        // TODO: test extracted_data=Slice
        .Varint => |varint_type| get_varint_value(int_type, varint_type, extracted_data.data.RawValue),
        // TODO: test extracted_data=Slice
        .FixedInt => get_fixed_value(int_type, extracted_data.data.RawValue),
        // TODO: test extracted_data=RawValue
        .SubMessage => try pb_decode(int_type, extracted_data.data.Slice, allocator),
        // TODO: test extracted_data=RawValue
        .String => extracted_data.data.Slice,
        else => @compileError(@typeName(int_type)),
    };
}

fn decode_data(comptime T: type, comptime field_desc: FieldDescriptor, comptime field: StructField, result: *T, extracted_data: Extracted, allocator: Allocator) !void {
    switch (field_desc.ftype) {
        .Varint, .FixedInt, .SubMessage, .String => {
            switch (@typeInfo(field.type)) {
                .Optional => {
                    const child_type = @typeInfo(field.type).Optional.child;
                    try set_value(T, child_type, field.name, result, field_desc.ftype, extracted_data, allocator);
                },
                else => {
                    try set_value(T, field.type, field.name, result, field_desc.ftype, extracted_data, allocator);
                },
            }
        },
        .List, .PackedList => |list_type| {
            const child_type = @typeInfo(@TypeOf(@field(result, field.name).items)).Pointer.child;

            if (field_desc.ftype == .PackedList) {
                // TODO: test extracted_data=RawValue
                try decode_packed_list(extracted_data.data.Slice, list_type, child_type, &@field(result, field.name));
            } else {
                switch (list_type) {
                    .Varint => |varint_type| {
                        switch (extracted_data.data) {
                            .RawValue => |value| {
                                try @field(result, field.name).append(get_varint_value(child_type, varint_type, value));
                            },
                            .Slice => |slice| {
                                try decode_packed_list(slice, list_type, child_type, &@field(result, field.name));
                            },
                        }
                    },
                    .FixedInt => |_| {
                        switch (extracted_data.data) {
                            .RawValue => |value| {
                                try @field(result, field.name).append(decode_fixed_raw(child_type, value));
                            },
                            .Slice => |slice| {
                                try decode_packed_list(slice, list_type, child_type, &@field(result, field.name));
                            },
                        }
                    },
                    .SubMessage, .String => switch (extracted_data.data) {
                        .Slice => |slice| try decode_list(slice, list_type, child_type, &@field(result, field.name), allocator),
                        .RawValue => @panic("TODO: TEST Invalid data"),
                    },
                }
            }
        },
        .Map => |map_data| {
            const map_type = get_map_submessage_type(map_data);
            // TODO: test extracted_data=RawValue
            var submessage_iterator = LengthDelimitedDecoderIterator{ .input = extracted_data.data.Slice };
            while (try submessage_iterator.next()) |slice| {
                var value = map_type.decode(slice, allocator);
                try @field(result, field.name).put(value.key.?, value.value.?);
            }
        },
        .OneOf => |_| {
            @compileError("Can not decode OneOf fields yet");
        },
    }
}

inline fn is_tag_known(comptime field_desc: FieldDescriptor, tag_to_check: Extracted) bool {
    if (field_desc.field_number) |field_number| {
        return field_number == tag_to_check.field_number;
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
            // @panic("unknown field");
        }
    }

    return result;
}

const testing = std.testing;

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

// length delimited message including a list of varints
test "unit varint packed - decode - multi-byte-varint" {
    const bytes = &[_]u8{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
    var list = ArrayList(u32).init(testing.allocator);
    defer list.deinit();

    try decode_packed_list(bytes, .{ .Varint = .Simple }, u32, &list);

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
    try testing.expectEqual(@as(i32, 1), get_varint_value(i32, .ZigZagOptimized, 2));
    try testing.expectEqual(@as(i32, -2), get_varint_value(i32, .ZigZagOptimized, 3));
    try testing.expectEqual(@as(i32, -500), get_varint_value(i32, .ZigZagOptimized, 999));
    try testing.expectEqual(@as(i64, -500), get_varint_value(i64, .ZigZagOptimized, 999));
    try testing.expectEqual(@as(i64, -0x80000000), get_varint_value(i64, .ZigZagOptimized, 0xffffffff));
}

test "zigzag i64 - encode" {
    var pb = ArrayList(u8).init(testing.allocator);
    defer pb.deinit();

    const input = "\xE7\x07";

    // -500 (.ZigZag)  encodes to {0xE7,0x07} which equals to 999 (.Simple)

    try append_as_varint(&pb, @as(i64, -500), .ZigZagOptimized);
    try testing.expectEqualSlices(u8, input, pb.items);
}
