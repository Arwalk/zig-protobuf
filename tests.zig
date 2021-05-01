const std = @import("std");
const protobuf = @import("src/protobuf.zig");
usingnamespace protobuf;
const testing = std.testing;
const eql = std.mem.eql;

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
        fd(2, "b", .Varint),
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

    const demo2 = Demo2{.a = 150, .b = 150};
    const obtained2 : ProtoBuf = try demo2.encode(testing.allocator);
    defer obtained2.deinit();
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01, 0x10, 0x96, 0x01}, obtained2.items);
}