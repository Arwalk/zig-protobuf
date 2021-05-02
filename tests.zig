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

    pub fn encode(self: Demo1, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "basic encoding" {
    var demo = Demo1{.a = 150};
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01}, obtained);

    demo.a = 0;
    const obtained2 = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x00}, obtained2);
}

const Demo2 = struct {
    a : u32,
    b : ?u32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .Varint),
        fd(2, "b", .Varint),
    };

    pub fn encode(self: Demo2, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "basic encoding with optionals" {
    const demo = Demo2{.a = 150, .b = null};
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01}, obtained);

    const demo2 = Demo2{.a = 150, .b = 150};
    const obtained2 = try demo2.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x96, 0x01, 0x10, 0x96, 0x01}, obtained2);
}

const WithNegativeIntegers = struct {
    a: i32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .Varint),
    };

    pub fn encode(self: WithNegativeIntegers, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "basic encoding with negative numbers" {
    var demo = WithNegativeIntegers{.a = -2};
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x03}, obtained);

    demo.a = 0;
    const obtained2 = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x00}, obtained2);
}

const DemoWithAllVarint = struct {
    
    const DemoEnum = enum {
        SomeValue,
        SomeOther,
        AndAnother
    };
    
    a: i32,  //sint32
    b: i64,  //sint64
    c: u32,  //uint32
    d: u64,  //uint64
    e: bool, //bool
    f: DemoEnum, // enum

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .Varint),
        fd(2, "b", .Varint),
        fd(3, "c", .Varint),
        fd(4, "d", .Varint),
        fd(5, "e", .Varint),
        fd(6, "f", .Varint),
    };

    pub fn encode(self: DemoWithAllVarint, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "DemoWithAllVarint" {
    var demo = DemoWithAllVarint{
        .a = -1,
        .b = -1,
        .c = 150,
        .d = 150,
        .e = true,
        .f = DemoWithAllVarint.DemoEnum.AndAnother,
    };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01, 0x30, 0x02}, obtained);
}