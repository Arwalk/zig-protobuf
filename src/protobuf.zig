const std = @import("std");
const testing = std.testing;


const ArrayList = std.ArrayList;

pub const ProtoBuf = ArrayList(u8);

pub const WireType = enum(u3){
    Varint = 0,
    Fixed64 = 1,
    LenDelimited = 2,
    Fixed32 = 5
};

pub const FieldDescriptor = struct {
    tag: u32,
    name: []const u8,
    wtype: WireType,
};

pub fn fd(tag: u32, name: []const u8, wtype: WireType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .name = name,
        .wtype = wtype
    };
}

fn encode_varint(pb : *ProtoBuf, value: anytype) !void {
    var size_in_bits : u32 = @bitSizeOf(@TypeOf(value)) - @clz(@TypeOf(value), value);

    if(size_in_bits == 0){
        try pb.append(0);
    }
    else
    {
        var val = value;
        while(val != 0) {
            try pb.append(0x80 + @intCast(u8, val & 0x7F));
            val = val >> 7;
        }
        pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
    }
}


fn _append(pb : *ProtoBuf, field: FieldDescriptor, value: anytype, allocator: *std.mem.Allocator) !void {
    try encode_varint(pb, ((field.tag << 3) | @enumToInt(field.wtype)));
    switch(field.wtype)
    {
        .Varint => {
            try encode_varint(pb, value);
        },
        else => @panic("Not implemented")
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) !ProtoBuf {
    const field_list  = @TypeOf(data)._desc_table;

    var pb = ProtoBuf.init(allocator);
    errdefer pb.deinit();

    inline for(field_list) |field| {
        if (@typeInfo(@TypeOf(@field(data, field.name))) == .Optional){
            if(@field(data, field.name)) |value| {
                try _append(&pb, field, value, allocator);
            }
        }
        else
        {
            try _append(&pb, field, @field(data, field.name), allocator);
        }
    }

    return pb;
}

test "get varint" {
    var pb = ProtoBuf.init(testing.allocator);
    defer pb.deinit();
    try encode_varint(&pb, @intCast(u32, 300));

    testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

