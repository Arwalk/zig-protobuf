const std = @import("std");
const protobuf = @import("src/protobuf.zig");
usingnamespace protobuf;
const testing = std.testing;
const eql = std.mem.eql;

const Demo1 = struct {
    a : u32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .{.Varint = .ZigZagOptimized}),
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
        fd(1, "a", .{.Varint = .ZigZagOptimized}),
        fd(2, "b", .{.Varint = .ZigZagOptimized}),
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
    a: i32, // int32
    b: i32, // sint32

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "a", .{.Varint = .ZigZagOptimized}),
        fd(2, "b", .{.Varint = .Simple}),
    };

    pub fn encode(self: WithNegativeIntegers, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "basic encoding with negative numbers" {
    var demo = WithNegativeIntegers{.a = -2, .b = -1};
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08
    testing.expectEqualSlices(u8, &[_]u8{0x08, 0x03, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F}, obtained);
}

const DemoWithAllVarint = struct {
    
    const DemoEnum = enum {
        SomeValue,
        SomeOther,
        AndAnother
    };
    
    sint32: i32,  //sint32
    sint64: i64,  //sint64
    uint32: u32,  //uint32
    uint64: u64,  //uint64
    a_bool: bool, //bool
    a_enum: DemoEnum, // enum
    pos_int32: i32,
    pos_int64: i64,
    neg_int32: i32,
    neg_int64: i64,


    pub const _desc_table = [_]FieldDescriptor{
        fd( 1, "sint32"     , .{.Varint = .ZigZagOptimized}),
        fd( 2, "sint64"     , .{.Varint = .ZigZagOptimized}),
        fd( 3, "uint32"     , .{.Varint = .ZigZagOptimized}),
        fd( 4, "uint64"     , .{.Varint = .ZigZagOptimized}),
        fd( 5, "a_bool"     , .{.Varint = .ZigZagOptimized}),
        fd( 6, "a_enum"     , .{.Varint = .ZigZagOptimized}),
        fd( 7, "pos_int32"  , .{.Varint = .Simple}),
        fd( 8, "pos_int64"  , .{.Varint = .Simple}),
        fd( 9, "neg_int32"  , .{.Varint = .Simple}),
        fd(10, "neg_int64"  , .{.Varint = .Simple}),
    };

    pub fn encode(self: DemoWithAllVarint, allocator: *std.mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }
};

test "DemoWithAllVarint" {
    var demo = DemoWithAllVarint{
        .sint32 = -1,
        .sint64 = -1,
        .uint32 = 150,
        .uint64 = 150,
        .a_bool = true,
        .a_enum = DemoWithAllVarint.DemoEnum.AndAnother,
        .pos_int32 = 1,
        .pos_int64 = 2,
        .neg_int32 = -1,
        .neg_int64 = -2
    };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    testing.expectEqualSlices(u8, &[_]u8{
            0x08, 0x01,
            0x10, 0x01,
            0x18, 0x96, 0x01,
            0x20, 0x96, 0x01,
            0x28, 0x01,
            0x30, 0x02,
            0x38, 0x01,
            0x40, 0x02,
            0x48, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F,
            0x50, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01
        },obtained);
}