const std = @import("std");
const testing = std.testing;
const isSignedInt = std.meta.trait.isSignedInt;

// common definitions

const ArrayList = std.ArrayList;

pub const ProtoBuf = ArrayList(u8);


pub const FieldType = enum{
    Varint,
    Fixed64,
    Fixed32,
    SubMessage,
    Bytes,
    List,
    PackedList,

    pub fn get_wirevalue(ftype : FieldType) u3 {
        return switch (ftype) {
            .Varint => 0,
            .Fixed64 => 1,
            .Fixed32 => 5,
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

fn append_varint(pb : *ProtoBuf, value: anytype) !void {
    

    if(value == 0){
        try pb.append(0);
    }
    else
    {
        var val = value;
        const type_of_val = @TypeOf(value);
        const bitsize = @bitSizeOf(type_of_val);
        
        if(isSignedInt(type_of_val)){ // zigzag encoding for signed types.
            val = switch(bitsize){
                32 => (val >> 31) ^ (val << 1),
                64 => (val >> 63) ^ (val << 1),
                else => val //comptime int is annoying.
            };
        }

        while(val != 0) {
            try pb.append(0x80 + @intCast(u8, val & 0x7F));
            val = val >> 7;
        }
        pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
    }
}


fn append(pb : *ProtoBuf, field: FieldDescriptor, value: anytype, allocator: *std.mem.Allocator) !void {
    try append_varint(pb, ((field.tag << 3) | field.ftype.get_wirevalue()));
    switch(field.ftype)
    {
        .Varint => {
            try append_varint(pb, value);
        },
        else => @panic("Not implemented")
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    const field_list  = @TypeOf(data)._desc_table;

    var pb = ProtoBuf.init(allocator);
    errdefer pb.deinit();

    inline for(field_list) |field| {
        if (@typeInfo(@TypeOf(@field(data, field.name))) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(&pb, field, value, allocator);
            }
        }
        else
        {
            try append(&pb, field, @field(data, field.name), allocator);
        }
    }

    return pb.toOwnedSlice();
}

// decoding

// TBD

// tests

test "get varint" {
    var pb = ProtoBuf.init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value);

    testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

