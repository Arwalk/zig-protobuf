const std = @import("std");
const protobuf = @import("protobuf");
const ArrayList = std.ArrayList;
const FieldDescriptor = protobuf.FieldDescriptor;
const mem = std.mem;
const pb_decode = protobuf.pb_decode;
const pb_encode = protobuf.pb_encode;
const pb_deinit = protobuf.pb_deinit;
const pb_init = protobuf.pb_init;
const fd = protobuf.fd;

const expected = @embedFile("encode_alltypes.output");

const SubMessage = struct {
    substuff1: ArrayList(u8),
    substuff2: ?i32,
    substuff3: ?i32,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "substuff1", .{ .List = .FixedInt }),
        fd(2, "substuff2", .{ .Varint = .Simple }),
        fd(3, "substuff3", .FixedInt),
    };

    pub fn encode(self: SubMessage, allocator: *mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: SubMessage) void {
        pb_deinit(self);
    }

    pub fn init(allocator: *mem.Allocator) SubMessage {
        return pb_init(SubMessage, allocator);
    }
};

const EmptyMessage = struct {
    pub const _desc_table = [_]FieldDescriptor{};

    pub fn encode(self: EmptyMessage, allocator: *mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: EmptyMessage) void {
        pb_deinit(self);
    }

    pub fn init(allocator: *mem.Allocator) EmptyMessage {
        return pb_init(EmptyMessage, allocator);
    }
};

const HugeEnum = enum(i32) { HE_Zero = 0, Negative = -2147483647, Positive = 2147483647 };

const Limits = struct {
    int32_min: ?i32,
    int32_max: ?i32,
    uint32_min: ?u32,
    uint32_max: ?u32,
    int64_min: ?i64,
    int64_max: ?i64,
    uint64_min: ?u64,
    uint64_max: ?u64,
    enum_min: ?HugeEnum,
    enum_max: ?HugeEnum,

    pub const _desc_table = [_]FieldDescriptor{
        fd(1, "int32_min", .{ .Varint = .ZigZagOptimized }),
        fd(2, "int32_max", .{ .Varint = .ZigZagOptimized }),
        fd(3, "uint32_min", .{ .Varint = .Simple }),
        fd(4, "uint32_max", .{ .Varint = .Simple }),
        fd(5, "int64_min", .{ .Varint = .ZigZagOptimized }),
        fd(6, "int64_max", .{ .Varint = .ZigZagOptimized }),
        fd(7, "uint64_min", .{ .Varint = .Simple }),
        fd(8, "uint64_max", .{ .Varint = .Simple }),
        fd(9, "enum_min", .{ .Varint = .ZigZagOptimized }),
        fd(10, "enum_max", .{ .Varint = .ZigZagOptimized }),
    };

    pub fn encode(self: Limits, allocator: *mem.Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: Limits) void {
        pb_deinit(self);
    }

    pub fn init(allocator: *mem.Allocator) Limits {
        return pb_init(Limits, allocator);
    }
};

const MyEnum = enum(type) {
    Zero = 0,
    First = 1,
    Second = 2,
    Truth = 42,
};

const AllTypes = struct {};

test "alltypes " {
    //todo!
}
