const std = @import("std");
const isSignedInt = std.meta.trait.isSignedInt;

// common definitions

const ArrayList = std.ArrayList;

pub const ProtoBuf = ArrayList(u8);

const VarintType = enum {
    Simple,
    ZigZagOptimized
};

pub const FieldTypeTag = enum{
    Varint,
    FixedInt,
    SubMessage,
    Bytes,
    List,
    PackedList,
};

pub const FieldType = union(FieldTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    Bytes,
    List,
    PackedList,

    pub fn get_wirevalue(ftype : FieldType, value: anytype) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => return switch(@bitSizeOf(@TypeOf(value))) {
                64 => 1,
                32 => 5,
                else => @panic("Invalid size for fixed int")
            },
            .SubMessage, .Bytes, .List, .PackedList => 2
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

fn encode_varint(pb: *ProtoBuf, value: anytype) !void {
    var copy = value;
    while(copy != 0) {
        try pb.append(0x80 + @intCast(u8, copy & 0x7F));
        copy = copy >> 7;
    }
    pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
}

fn insert_size_as_varint(pb: *ProtoBuf, size: u64, start_index: usize) !void {
    if(size < 0x7F){
        try pb.insert(start_index, @intCast(u8, size));
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

fn append_as_varint(pb: *ProtoBuf, value: anytype, varint_type: VarintType) !void {
    if(value < 0x7F and value >= 0){
        try pb.append(@intCast(u8, value));
    }
    else
    {
        const type_of_val = @TypeOf(value);
        const bitsize = @bitSizeOf(type_of_val);
        var val = value;

        if(isSignedInt(type_of_val)){
            switch(varint_type) {
                .ZigZagOptimized => {
                    try encode_varint(pb, (value >> (bitsize-1)) ^ (value << 1));
                },
                .Simple => {
                    var as_unsigned = @ptrCast(*std.meta.Int(.unsigned, bitsize), &val);
                    try encode_varint(pb, as_unsigned.*);
                    return;
                }
            }
        }
        else
        {
            try encode_varint(pb, val);
        }   
    }
}

fn append_varint(pb : *ProtoBuf, value: anytype, varint_type: VarintType) !void {
    switch(@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @intCast(i32, @enumToInt(value)), varint_type),
        .Bool => try append_as_varint(pb, @intCast(u8, @boolToInt(value)), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

fn append_fixed(pb : *ProtoBuf, value: anytype) !void {
    var copy = value;
    const bitsize = @bitSizeOf(@TypeOf(value));
    var as_unsigned_int = @ptrCast(*std.meta.Int(.unsigned, bitsize), &copy).*;

    var index : usize = 0;

    while(index < (bitsize/8)) : (index += 1) {
        try pb.append(@intCast(u8, as_unsigned_int & 0xFF));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

fn append_submessage(pb :* ProtoBuf, value: anytype) !void {
    const len_index = pb.items.len;
    try internal_pb_encode(pb, value);
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append(pb : *ProtoBuf, comptime field: FieldDescriptor, value: anytype) !void {
    try append_varint(pb, ((field.tag << 3) | field.ftype.get_wirevalue(value)), .Simple);
    switch(field.ftype)
    {
        .Varint => |varint_type| {
            try append_varint(pb, value, varint_type);
        },
        .FixedInt => try append_fixed(pb, value),
        .SubMessage => try append_submessage(pb, value),
        else => @panic("Not implemented")
    }
}

fn internal_pb_encode(pb : *ProtoBuf, data: anytype) !void {
    const field_list  = @TypeOf(data)._desc_table;

    inline for(field_list) |field| {
        if (@typeInfo(@TypeOf(@field(data, field.name))) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(pb, field, value);
            }
        }
        else
        {
            try append(pb, field, @field(data, field.name));
        }
    }

    
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    var pb = ProtoBuf.init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);
    
    return pb.toOwnedSlice();
}

// decoding

// TBD

// tests

const testing = std.testing;

test "get varint" {
    var pb = ProtoBuf.init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value, .Simple);

    testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

