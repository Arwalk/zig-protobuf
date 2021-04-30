const std = @import("std");
const testing = std.testing;
const eql = std.mem.eql;

const ArrayList = std.ArrayList;

const ProtoBuf = ArrayList(u8);

const FieldStatus = enum {
    Required,
    Optional
};

const WireType = enum(u3){
    Varint = 0,
    Fixed64 = 1,
    LenDelimited = 2,
    Fixed32 = 5
};

const FieldDescriptor = struct {
    tag: u5,
    name: []const u8,
    wtype: WireType,
};

pub fn fd(tag: u5, name: []const u8, wtype: WireType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .name = name,
        .wtype = wtype
    };
}

fn as_varint(value: anytype, allocator: *std.mem.Allocator) !ProtoBuf {
    var size_in_bits : u32 = @bitSizeOf(@TypeOf(value)) - @clz(@TypeOf(value), value);
    var pb = ProtoBuf.init(allocator);

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

    return pb;
}

fn _append(pb : *ProtoBuf, field: FieldDescriptor, value: anytype, allocator: *std.mem.Allocator) !void {
    try pb.append((field.tag << 3) + @enumToInt(field.wtype));
    switch(field.wtype)
    {
        .Varint => {
            const varint = try as_varint(value, allocator);
            defer varint.deinit();
            try pb.appendSlice(varint.items);
        },
        else => @panic("Not implemented")
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) !ProtoBuf {
    const field_list  = @field(@TypeOf(data), "_desc_table");

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
    const obtained = try as_varint(@intCast(u32, 300), testing.allocator);
    defer obtained.deinit();

    testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, obtained.items);
}

const Demo1 = struct {
    a : u32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .Varint),
    };

    pub fn encode(self: Demo1, allocator: *std.mem.Allocator) !ProtoBuf {
        return pb_encode(self, allocator);
    }
};

const Demo2 = struct {
    a : u32,
    b : ?u32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .Varint),
        fd(1, "b", .Varint),
    };

    pub fn encode(self: Demo2, allocator: *std.mem.Allocator) !ProtoBuf {
        return pb_encode(self, allocator);
    }
};

test "basic encoding" {
    const demo = Demo1{.a = 150};
    const obtained : ProtoBuf = try demo.encode(testing.allocator);
    defer obtained.deinit();
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01}, obtained.items);
}

test "basic encoding with optionals" {
    const demo = Demo2{.a = 150, .b = null};
    const obtained : ProtoBuf = try demo.encode(testing.allocator);
    defer obtained.deinit();
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01}, obtained.items);
}