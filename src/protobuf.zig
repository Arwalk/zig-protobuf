const std = @import("std");
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

pub const FieldType = union(FieldTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,

    pub fn get_wirevalue(ftype : FieldType, comptime value_type: type) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => return switch(@bitSizeOf(value_type)) {
                64 => 1,
                32 => 5,
                else => @panic("Invalid size for fixed int")
            },
            .SubMessage, .List => 2,            
        };
    }
};

pub const FieldDescriptor = struct {
    tag: u32,
    name: []const u8,
    ftype: FieldType,
};

pub fn fd(tag: u32, name: []const u8, ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .name = name,
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
    var copy = value;
    const bitsize = @bitSizeOf(@TypeOf(value));
    var as_unsigned_int = @bitCast(std.meta.Int(.unsigned, bitsize), copy);

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
    try append_varint(pb, ((field.tag << 3) | field.ftype.get_wirevalue(value_type)), .Simple);
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
        }
    }
}

fn internal_pb_encode(pb : *ArrayList(u8), data: anytype) !void {
    const field_list  = @TypeOf(data)._desc_table;

    inline for(field_list) |field| {
        if (@typeInfo(@TypeOf(@field(data, field.name))) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(pb, field, @TypeOf(value), value);
            }
        }
        else
        {
            if(@field(data, field.name).items.len != 0){
                try append(pb, field, @TypeOf(@field(data, field.name)), @field(data, field.name));
            }
        }
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    var pb = ProtoBuf.init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);
    
    return pb.toOwnedSlice();
}

fn get_struct_field(comptime T: type, comptime field_name: []const u8 ) std.builtin.TypeInfo.StructField {
    return inline for (@typeInfo(T).Struct.fields) |field| {
        if(std.mem.eql(u8, field.name, field_name)) {
            break field;
        }
    } else @compileLog("Could not find field ", field_name, " in struct", T);
}

pub fn pb_init(comptime T: type, allocator : *std.mem.Allocator) T {

    comptime {
        if(@typeInfo(T).Struct.fields.len != T._desc_table.len) {
            @compileLog("malformed structure or desc table for structure", T);
            @compileLog("@typeInfo(T).Struct.fields.len =", @typeInfo(T).Struct.fields.len);
            @compileLog("T._desc_table.len =", T._desc_table.len);
        }
    }

    var value: T = undefined;

    inline for (T._desc_table) |field| {
        switch (field.ftype) {
            .Varint, .FixedInt => {
                const struct_field = get_struct_field(T, field.name);
                @field(value, field.name) = if(struct_field.default_value) |val| val else null;
            },
            .SubMessage, .List => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
        }
    }

    return value;
}

pub fn pb_deinit(data: anytype) void {
    const field_list  = @TypeOf(data)._desc_table;

    inline for(field_list) |field| {
        switch (field.ftype) {
            .Varint, .FixedInt => {},
            .SubMessage => {
                @field(data, field.name).deinit();
            },
            .List => |list_type| {
                if(list_type == .SubMessage) {
                    for(@field(data, field.name).items) |item| {
                        item.deinit();
                    }
                }
                @field(data, field.name).deinit();
            }
        }
    }
}

// decoding

// TBD

// tests

const testing = std.testing;

test "get varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value, .Simple);

    testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

