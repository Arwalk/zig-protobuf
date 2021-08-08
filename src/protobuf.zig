const std = @import("std");
const StructField = std.builtin.TypeInfo.StructField;
const isSignedInt = std.meta.trait.isSignedInt;

// common definitions

const ArrayList = std.ArrayList;

const VarintType = enum {
    Simple,
    ZigZagOptimized
};

pub const FieldTypeTag = enum{
    Varint,
    FixedInt,
    SubMessage,
    List,
    OneOf,
    Map
};

pub const ListTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
};

pub const ListType = union(ListTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
};

pub const KeyValueTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
    List,

};

pub const  KeyValueType = union(KeyValueTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,

    pub fn toFieldType(self: KeyValueType) FieldType {
        return switch(self)
        {
            .Varint => |varint_type| .{.Varint = varint_type},
            .FixedInt => .{.FixedInt},
            .SubMessage => .{.SubMessage},
            .List => |list_type| .{.List = list_type}
        };
    }
};

pub const KeyValueTypeData = struct {
    t: type,
    pb_data: KeyValueType,
};

pub const KeyValueData = struct {
    key: KeyValueTypeData,
    value: KeyValueTypeData
};

pub const FieldType = union(FieldTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,
    OneOf: type,
    Map: KeyValueData,

    pub fn get_wirevalue(comptime ftype : FieldType, comptime value_type: type) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => return switch(@bitSizeOf(value_type)) {
                64 => 1,
                32 => 5,
                else => @panic("Invalid size for fixed int")
            },
            .SubMessage, .List, .Map => 2,
            .OneOf => unreachable,
        };
    }
};

pub const FieldDescriptor = struct {
    tag: ?u32,
    ftype: FieldType,
};

pub fn fd(tag: ?u32, comptime ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .ftype = ftype
    };
}

// encoding

fn encode_varint(pb: *ArrayList(u8), value: anytype) !void {
    var copy = value;
    while(copy != 0) {
        try pb.append(0x80 + @intCast(u8, copy & 0x7F));
        copy = copy >> 7;
    }
    pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
}

fn insert_size_as_varint(pb: *ArrayList(u8), size: u64, start_index: usize) !void {
    if(size < 0x7F){
        try pb.insert(start_index, @truncate(u8, size));
    }
    else
    {
        var copy = size;
        var index = start_index;
        while(copy != 0) : (index += 1 ) {
            try pb.insert(index, 0x80 + @intCast(u8, copy & 0x7F));
            copy = copy >> 7;
        }
        pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
    }
}

fn append_as_varint(pb: *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    if(value < 0x7F and value >= 0){
        try pb.append(@intCast(u8, value));
    }
    else
    {
        const type_of_val = @TypeOf(value);
        const bitsize = @bitSizeOf(type_of_val);
        const val : u64 = comptime blk: {
            if(isSignedInt(type_of_val)){
                switch(varint_type) {
                    .ZigZagOptimized => {
                        break :blk @intCast(u64, (value >> (bitsize-1)) ^ (value << 1));
                    },
                    .Simple => {
                        break :blk @ptrCast(*const std.meta.Int(.unsigned, bitsize), &value).*;
                    }
                }
            }
            else
            {
                break :blk @intCast(u64, value);
            }   
        };

        try encode_varint(pb, val);
    }
}

fn append_varint(pb : *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    switch(@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @as(i32, @enumToInt(value)), varint_type),
        .Bool => try append_as_varint(pb, @as(u8, @boolToInt(value)), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

fn append_fixed(pb : *ArrayList(u8), value: anytype) !void {
    const bitsize = @bitSizeOf(@TypeOf(value));
    var as_unsigned_int = @bitCast(std.meta.Int(.unsigned, bitsize), value);

    var index : usize = 0;

    while(index < (bitsize/8)) : (index += 1) {
        try pb.append(@truncate(u8, as_unsigned_int));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

fn append_submessage(pb :* ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    try internal_pb_encode(pb, value);
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_bytes(pb: *ArrayList(u8), value: *const ArrayList(u8)) !void {
    const len_index = pb.items.len;
    try pb.appendSlice(value.items);
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_fixed(pb: *ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    if(@TypeOf(value) == ArrayList(u8)) {
        try pb.appendSlice(value.items);
    }
    else {
        for(value.items) |item| {
            try append_fixed(pb, item);
        }
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_varint(pb : *ArrayList(u8), value_list: anytype, comptime varint_type: VarintType) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_varint(pb, item, varint_type);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_submessages(pb: *ArrayList(u8), value_list: anytype) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_submessage(pb, item);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_tag(pb : *ArrayList(u8), comptime field: FieldDescriptor,  value_type: type) !void {
    if(field.tag) |tag|{
        try append_varint(pb, ((tag << 3) | field.ftype.get_wirevalue(value_type)), .Simple);
    }
}


fn append_map(pb : *ArrayList(u8), comptime field: FieldDescriptor, map: anytype) !void {
    const len_index = pb.items.len;
    var iterator : @TypeOf(map).Iterator = map.iterator();
    const key_type_data = field.ftype.Map.key;
    const value_type_data = field.ftype.Map.value;
    const Submessage = struct {
        key : ?key_type_data.t,
        value : ?value_type_data.t,

        pub const _desc_table = .{
            .key = fd(1, key_type_data.pb_data.toFieldType()),
            .value = fd(2, value_type_data.pb_data.toFieldType())
        };

        pub fn encode(self: Submessage, allocator: *mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
        }

        pub fn init(allocator: *mem.Allocator) Submessage {
            return pb_init(Submessage, allocator);
        }

        pub fn deinit(self: Submessage) void {
            pb_deinit(self);
        }
    };
    while (iterator.next()) |data| {
        try append_submessage(pb, Submessage{.key = data.key_ptr.*, .value = data.value_ptr.*});
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append(pb : *ArrayList(u8), comptime field: FieldDescriptor, value_type: type, value: anytype) !void {
    try append_tag(pb, field, value_type);
    switch(field.ftype)
    {
        .Varint => |varint_type| {
            try append_varint(pb, value, varint_type);
        },
        .FixedInt => {
            try append_fixed(pb, value);  
        },
        .SubMessage => {
            try append_submessage(pb, value);
        },
        .List => |list_type| {
            switch(list_type) {
                .FixedInt => {
                    try append_list_of_fixed(pb, value);
                },
                .SubMessage => {
                    try append_list_of_submessages(pb, value);
                },
                .Varint => |varint_type| {
                    try append_list_of_varint(pb, value, varint_type);
                }
            }
        },
        .OneOf => |union_type| {
            const active = @tagName(value);
            inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                if(std.mem.eql(u8, union_field.name, active)) {
                    try append(pb, @field(union_type._union_desc, union_field.name), @TypeOf(@field(value, union_field.name)), @field(value, union_field.name));
                }
            }
        },
        .Map => {        
            try append_map(pb, field, value);    
        }
    }
}

fn internal_pb_encode(pb : *ArrayList(u8), data: anytype) !void {
    const field_list  = @typeInfo(@TypeOf(data)).Struct.fields;
    const data_type = @TypeOf(data);

    inline for(field_list) |field| {
        if (@typeInfo(field.field_type) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(pb, @field(data_type._desc_table, field.name), @TypeOf(value), value);
            }
        }
        else
        {
            switch(@field(data_type._desc_table, field.name).ftype)
            {
                .List => if(@field(data, field.name).items.len != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @TypeOf(@field(data, field.name)), @field(data, field.name));
                },
                .Map => if(@field(data, field.name).count() != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @TypeOf(@field(data, field.name)), @field(data, field.name));
                },
                else => @compileLog("You shouldn't be here")
            }
        }
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    var pb = ArrayList(u8).init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);
    
    return pb.toOwnedSlice();
}

pub fn pb_init(comptime T: type, allocator : *std.mem.Allocator) T {

    var value: T = undefined;

    inline for (@typeInfo(T).Struct.fields) |field| {
        switch (@field(T._desc_table, field.name).ftype) {
            .Varint, .FixedInt => {
                @field(value, field.name) = if(field.default_value) |val| val else null;
            },
            .SubMessage, .List, .Map => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
            .OneOf => {
                @field(value, field.name) = null;
            }
        }
    }

    return value;
}

fn deinit_field(field: anytype, comptime field_name: []const u8, comptime ftype: FieldType) void {
    switch(ftype) {
        .Varint, .FixedInt => {},
        .SubMessage => {
            @field(field, field_name).deinit();
        },
        .List => |list_type| {
            if(list_type == .SubMessage) {
                for(@field(field, field_name).items) |item| {
                    item.deinit();
                }
            }
            @field(field, field_name).deinit();
        },
        .OneOf => |union_type| {
            if(@field(field, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                    if(std.mem.eql(u8, union_field.name, active)) {
                        deinit_field(union_value, union_field.name, @field(union_type._union_desc, union_field.name).ftype);
                    }
                } 
            } 
        },
        .Map => |_| {
            // for unknown reason i have to specifically made it var here. Otherwise it's a const field.
            var temp = @field(field, field_name); // key/values requiring dealloc aren't managed yet!
            temp.deinit();
        }
    }
}

pub fn pb_deinit(data: anytype) void {
    const T  = @TypeOf(data);

    inline for (@typeInfo(T).Struct.fields) |field| {
        deinit_field(data, field.name, @field(T._desc_table, field.name).ftype);
    }
}

// decoding

const ExtractedDataTag = enum {
    RawValue,
    Slice,
};

const ExtractedData = union(ExtractedDataTag) {
    RawValue : u64,
    Slice: []const u8
};

const Extracted = struct {
    tag: u32,
    data: ExtractedData
};

fn DecodedVarint(comptime T: type) type {
    return struct {
        value: T,
        size: usize,
    };
}

fn decode_varint(comptime T: type, input: []const u8) DecodedVarint(T) {
    var value: T = 0;
    var index: usize = 0;

    while((input[index] & 0b10000000) != 0) : (index += 1) {
        value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));
    }

    value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));

    return DecodedVarint(T){
        .value = value,
        .size = index +1,
    };
}

fn decode_fixed(comptime T : type, slice: []const u8) T {
    var result : T = 0;

    for(slice) |byte, index| {
        result += @as(T, byte) << (@intCast(std.math.Log2Int(T), index * 8));
    }
    return result;
}

const WireDecoderIterator = struct {
    input: []const u8,
    current_index : usize = 0,

    fn next(state: *WireDecoderIterator) !?Extracted {
        if(state.current_index < state.input.len) {
            const tag_and_wire = decode_varint(u32, state.input[state.current_index..]);
            state.current_index += tag_and_wire.size;
            const tag : u32 = (tag_and_wire.value >> 3);
            const wire_value = tag_and_wire.value & 0b00000111;
            const data : ExtractedData = switch(wire_value) {
                0 => blk: {
                    const varint = decode_varint(u64, state.input[state.current_index..]);
                    state.current_index += varint.size;
                    break :blk ExtractedData{
                        .RawValue = varint.value,
                    };
                },
                1 => blk: {
                        const value = ExtractedData{.RawValue = decode_fixed(u64, state.input[state.current_index..state.current_index+8])};
                        state.current_index += 8;
                        break :blk value;
                },
                5 => blk: {
                        const value = ExtractedData{.RawValue = decode_fixed(u32, state.input[state.current_index..state.current_index+4])};
                        state.current_index += 4;
                        break :blk value;
                },
                else => @panic("Not implemented yet")
            };

            return Extracted{
                .tag = tag,
                .data = data
            };
        }
        else
        {
            return null;
        }    
    }
};

fn get_descriptor(comptime fields : []const FieldDescriptor, tag: u32) ?*const FieldDescriptor {
    return inline for(fields) |*desc| {
        if(desc.tag == tag) break desc;
    } else null;
}

const FullFieldDescriptor = struct {
    field_name: []const u8,
    tag: u32,
    pb_type: FieldType,
    real_type: type
};

fn get_varint_value(comptime T : type, comptime varint_type : VarintType, raw: u64) T {
    return comptime switch(varint_type) {
        .ZigZagOptimized => 
            switch (@typeInfo(T)) {
                .Int =>  @intCast(T, (@intCast(i64, raw) >> 1) ^ (-(@intCast(i64, raw) & 1))),
                .Enum => @intToEnum(T, @intCast(i32, (@intCast(i64, raw) >> 1) ^ (-(@intCast(i64, raw) & 1)))),
                else => unreachable
            }
        ,
        .Simple =>
            switch (@typeInfo(T)) {
                .Int => switch(T) {
                    u32, u64 => @intCast(T, raw),
                    i32, i64 => @bitCast(T, @truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)),
                    else => unreachable
                },
                .Bool => raw == 1,
                .Enum => @intToEnum(T, @intCast(i32, raw)),
                else => unreachable
            }
    };
}

fn get_fixed_value(comptime T: type, raw: u64) T {
    return switch(T) {
        i32, u32, i64, u64 => @ptrCast(*const T, &@truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)).*,
        f32, f64 => @ptrCast(*T, &@intCast(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)).*,
        else => @compileLog("Not implemented")
    };
}

pub fn pb_decode(comptime T: type, input: []const u8, allocator: *std.mem.Allocator) !T {
    var result = pb_init(T, allocator);
    
    var iterator = WireDecoderIterator{.input = input};

    while(try iterator.next()) |extracted_data| {
        
        const field_found : ?StructField = inline for (@typeInfo(T).Struct.fields) |field| {
            if(@field(T._desc_table, field.name).tag == extracted_data.tag) break field;
        } else null;

        if(field_found) |field| {
            const child_type = @typeInfo(field.field_type).Optional.child;
            
            @field(result, field.name) = switch(@field(T._desc_table, field.name).ftype) {
                .Varint => |varint_type| get_varint_value(child_type, varint_type, extracted_data.data.RawValue),
                .FixedInt => get_fixed_value(child_type, extracted_data.data.RawValue),
                else => @panic("Not implemented")
            };
        }
    }

    return result;
}

// TBD

// tests

const testing = std.testing;

test "get varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value, .Simple);

    try testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

