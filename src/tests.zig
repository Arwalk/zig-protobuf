const std = @import("std");
const protobuf = @import("protobuf.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const eql = mem.eql;
const fd = protobuf.fd;
const pb_decode = protobuf.pb_decode;
const pb_encode = protobuf.pb_encode;
const pb_deinit = protobuf.pb_deinit;
const pb_init = protobuf.pb_init;
const testing = std.testing;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const FieldType = protobuf.FieldType;

const Demo1 = struct {
    a: ?u32,

    pub const _desc_table = .{ .a = fd(1, FieldType{ .Varint = .Simple }) };

    pub fn encode(self: Demo1, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !Demo1 {
        return pb_decode(Demo1, input, allocator);
    }

    pub fn deinit(self: Demo1) void {
        pb_deinit(self);
    }
};

test "basic encoding" {
    var demo = Demo1{ .a = 150 };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained);

    demo.a = 0;
    const obtained2 = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, obtained2);
}

test "basic decoding" {
    const input = [_]u8{ 0x08, 0x96, 0x01 };
    const obtained = try Demo1.decode(&input, testing.allocator);

    try testing.expectEqual(Demo1{ .a = 150 }, obtained);

    const input2 = [_]u8{ 0x08, 0x00 };
    const obtained2 = try Demo1.decode(&input2, testing.allocator);
    try testing.expectEqual(Demo1{ .a = 0 }, obtained2);
}

const Demo2 = struct {
    a: ?u32,
    b: ?u32,

    pub const _desc_table = .{
        .a = fd(1, .{ .Varint = .Simple }),
        .b = fd(2, .{ .Varint = .Simple }),
    };

    pub fn encode(self: Demo2, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: Demo2) void {
        pb_deinit(self);
    }
};

test "basic encoding with optionals" {
    const demo = Demo2{ .a = 150, .b = null };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained);

    const demo2 = Demo2{ .a = 150, .b = 150 };
    const obtained2 = try demo2.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01, 0x10, 0x96, 0x01 }, obtained2);
}

const WithNegativeIntegers = struct {
    a: ?i32, // int32
    b: ?i32, // sint32

    pub const _desc_table = .{
        .a = fd(1, .{ .Varint = .ZigZagOptimized }),
        .b = fd(2, .{ .Varint = .Simple }),
    };

    pub fn encode(self: WithNegativeIntegers, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: WithNegativeIntegers) void {
        pb_deinit(self);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !WithNegativeIntegers {
        return pb_decode(WithNegativeIntegers, input, allocator);
    }
};

test "basic encoding with negative numbers" {
    var demo = WithNegativeIntegers{ .a = -2, .b = -1 };
    const obtained = try demo.encode(testing.allocator);
    defer demo.deinit();
    defer testing.allocator.free(obtained);
    // 0x08
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x03, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, obtained);
    const decoded = try WithNegativeIntegers.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

const DemoWithAllVarint = struct {
    const DemoEnum = enum(i32) { SomeValue, SomeOther, AndAnother };

    sint32: ?i32, //sint32
    sint64: ?i64, //sint64
    uint32: ?u32, //uint32
    uint64: ?u64, //uint64
    a_bool: ?bool, //bool
    a_enum: ?DemoEnum, // enum
    pos_int32: ?i32,
    pos_int64: ?i64,
    neg_int32: ?i32,
    neg_int64: ?i64,

    pub const _desc_table = .{
        .sint32 = fd(1, .{ .Varint = .ZigZagOptimized }),
        .sint64 = fd(2, .{ .Varint = .ZigZagOptimized }),
        .uint32 = fd(3, .{ .Varint = .Simple }),
        .uint64 = fd(4, .{ .Varint = .Simple }),
        .a_bool = fd(5, .{ .Varint = .Simple }),
        .a_enum = fd(6, .{ .Varint = .Simple }),
        .pos_int32 = fd(7, .{ .Varint = .Simple }),
        .pos_int64 = fd(8, .{ .Varint = .Simple }),
        .neg_int32 = fd(9, .{ .Varint = .Simple }),
        .neg_int64 = fd(10, .{ .Varint = .Simple }),
    };

    pub fn encode(self: DemoWithAllVarint, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !DemoWithAllVarint {
        return pb_decode(DemoWithAllVarint, input, allocator);
    }

    pub fn deinit(self: DemoWithAllVarint) void {
        pb_deinit(self);
    }
};

test "DemoWithAllVarint" {
    var demo = DemoWithAllVarint{ .sint32 = -1, .sint64 = -1, .uint32 = 150, .uint64 = 150, .a_bool = true, .a_enum = DemoWithAllVarint.DemoEnum.AndAnother, .pos_int32 = 1, .pos_int64 = 2, .neg_int32 = -1, .neg_int64 = -2 };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01, 0x30, 0x02, 0x38, 0x01, 0x40, 0x02, 0x48, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x50, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }, obtained);

    const decoded = try DemoWithAllVarint.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

const WithSubmessages = struct {
    sub_demo1: ?Demo1,
    sub_demo2: ?Demo2,

    pub const _desc_table = .{
        .sub_demo1 = fd(1, .SubMessage),
        .sub_demo2 = fd(2, .SubMessage),
    };

    pub fn encode(self: WithSubmessages, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: WithSubmessages) void {
        pb_deinit(self);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !WithSubmessages {
        return pb_decode(WithSubmessages, input, allocator);
    }

    pub fn init(allocator: Allocator) WithSubmessages {
        return pb_init(WithSubmessages, allocator);
    }
};

test "WithSubmessages" {
    var demo = WithSubmessages{ .sub_demo1 = .{ .a = 1 }, .sub_demo2 = .{ .a = 2, .b = 3 } };

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08 + 2, 0x02, 0x08, 0x01, 0x10 + 2, 0x04, 0x08, 0x02, 0x10, 0x03 }, obtained);

    const decoded = try WithSubmessages.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

const WithBytes = struct {
    list_of_data: ArrayList(u8),

    pub const _desc_table = .{
        .list_of_data = fd(1, .{ .List = .FixedInt }),
    };

    pub fn encode(self: WithBytes, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: WithBytes) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) WithBytes {
        return pb_init(WithBytes, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !WithBytes {
        return pb_decode(WithBytes, input, allocator);
    }
};

test "bytes" {
    var demo = WithBytes.init(testing.allocator);
    try demo.list_of_data.append(0x08);
    try demo.list_of_data.append(0x01);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2, 0x02,
        0x08,     0x01,
    }, obtained);

    const decoded = try WithBytes.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, demo.list_of_data.items, decoded.list_of_data.items);
}

const FixedSizesList = struct {
    fixed32List: ArrayList(u32),

    pub const _desc_table = .{
        .fixed32List = fd(1, .{ .List = .FixedInt }),
    };

    pub fn encode(self: FixedSizesList, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: FixedSizesList) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) FixedSizesList {
        return pb_init(FixedSizesList, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !FixedSizesList {
        return pb_decode(FixedSizesList, input, allocator);
    }
};

fn log_slice(slice: []const u8) void {
    std.log.warn("{}", .{std.fmt.fmtSliceHexUpper(slice)});
}

test "FixedSizesList" {
    var demo = FixedSizesList.init(testing.allocator);
    try demo.fixed32List.append(0x01);
    try demo.fixed32List.append(0x02);
    try demo.fixed32List.append(0x03);
    try demo.fixed32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2, 0x10,
        0x01,     0x00,
        0x00,     0x00,
        0x02,     0x00,
        0x00,     0x00,
        0x03,     0x00,
        0x00,     0x00,
        0x04,     0x00,
        0x00,     0x00,
    }, obtained);

    const decoded = try FixedSizesList.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.fixed32List.items, decoded.fixed32List.items);
}

const VarintList = struct {
    varuint32List: ArrayList(u32),

    pub const _desc_table = .{
        .varuint32List = fd(1, .{ .List = .{ .Varint = .Simple } }),
    };

    pub fn encode(self: VarintList, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: VarintList) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) VarintList {
        return pb_init(VarintList, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !VarintList {
        return pb_decode(VarintList, input, allocator);
    }
};

test "VarintList" {
    var demo = VarintList.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2, 0x04,
        0x01,     0x02,
        0x03,     0x04,
    }, obtained);

    const decoded = try VarintList.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
}

const SubMessageList = struct {
    subMessageList: ArrayList(Demo1),

    pub const _desc_table = .{
        .subMessageList = fd(1, .{ .List = .SubMessage }),
    };

    pub fn encode(self: SubMessageList, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: SubMessageList) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) SubMessageList {
        return pb_init(SubMessageList, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !SubMessageList {
        return pb_decode(SubMessageList, input, allocator);
    }
};

// .{.a = 1}

test "SubMessageList" {
    var demo = SubMessageList.init(testing.allocator);
    try demo.subMessageList.append(.{ .a = 1 });
    try demo.subMessageList.append(.{ .a = 2 });
    try demo.subMessageList.append(.{ .a = 3 });
    try demo.subMessageList.append(.{ .a = 4 });
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2,
        0x0C,
        0x02,
        0x08,
        0x01,
        0x02,
        0x08,
        0x02,
        0x02,
        0x08,
        0x03,
        0x02,
        0x08,
        0x04,
    }, obtained);

    const decoded = try SubMessageList.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(Demo1, demo.subMessageList.items, decoded.subMessageList.items);
}

const EmptyLists = struct {
    varuint32List: ArrayList(u32),
    varuint32Empty: ArrayList(u32),

    pub const _desc_table = .{
        .varuint32List = fd(1, .{ .List = .{ .Varint = .Simple } }),
        .varuint32Empty = fd(2, .{ .List = .{ .Varint = .Simple } }),
    };

    pub fn encode(self: EmptyLists, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: EmptyLists) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) EmptyLists {
        return pb_init(EmptyLists, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !EmptyLists {
        return pb_decode(EmptyLists, input, allocator);
    }
};

test "EmptyLists" {
    var demo = EmptyLists.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2, 0x04,
        0x01,     0x02,
        0x03,     0x04,
    }, obtained);

    const decoded = try EmptyLists.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
    try testing.expectEqualSlices(u32, demo.varuint32Empty.items, decoded.varuint32Empty.items);
}

const EmptyMessage = struct {
    pub const _desc_table = .{};

    pub fn encode(self: EmptyMessage, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn deinit(self: EmptyMessage) void {
        pb_deinit(self);
    }

    pub fn init(allocator: Allocator) EmptyMessage {
        return pb_init(EmptyMessage, allocator);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !EmptyMessage {
        return pb_decode(EmptyMessage, input, allocator);
    }
};

test "EmptyMessage" {
    var demo = EmptyMessage.init(testing.allocator);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{}, obtained);

    const decoded = try EmptyMessage.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqual(demo, decoded);
}

const DefaultValuesInit = struct {
    a: ?u32 = 5,
    b: ?u32,
    c: ?u32 = 3,
    d: ?u32,

    pub const _desc_table = .{
        .a = fd(1, .{ .Varint = .Simple }),
        .b = fd(2, .{ .Varint = .Simple }),
        .c = fd(3, .{ .Varint = .Simple }),
        .d = fd(4, .{ .Varint = .Simple }),
    };

    pub fn encode(self: DefaultValuesInit, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn init(allocator: Allocator) DefaultValuesInit {
        return pb_init(DefaultValuesInit, allocator);
    }

    pub fn deinit(self: DefaultValuesInit) void {
        pb_deinit(self);
    }
};

test "DefaultValuesInit" {
    var demo = DefaultValuesInit.init(testing.allocator);
    try testing.expectEqual(@as(u32, 5), demo.a.?);
    try testing.expectEqual(@as(u32, 3), demo.c.?);
    try testing.expect(if (demo.b) |_| false else true);
    try testing.expect(if (demo.d) |_| false else true);
}

const OneOfDemo = struct {
    const a_case = enum { value_1, value_2 };

    const a_union = union(a_case) {
        value_1: u32,
        value_2: ArrayList(u32),

        pub const _union_desc = .{ .value_1 = fd(1, .{ .Varint = .Simple }), .value_2 = fd(2, .{ .List = .{ .Varint = .Simple } }) };
    };

    a: ?a_union,

    pub const _desc_table = .{ .a = fd(null, .{ .OneOf = a_union }) };

    pub fn encode(self: OneOfDemo, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn init(allocator: Allocator) OneOfDemo {
        return pb_init(OneOfDemo, allocator);
    }

    pub fn deinit(self: OneOfDemo) void {
        pb_deinit(self);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !OneOfDemo {
        return pb_decode(OneOfDemo, input, allocator);
    }
};

test "OneOfDemo" {
    var demo = OneOfDemo.init(testing.allocator);
    defer demo.deinit();

    demo.a = .{ .value_1 = 10 };

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x08, 10,
    }, obtained);
    // const decoded = try OneOfDemo.decode(obtained, testing.allocator);
    // defer decoded.deinit();
    // try testing.expectEqual(demo.a.?.value_1, decoded.a.?.value_1);

    demo.a = .{ .value_2 = ArrayList(u32).init(testing.allocator) };
    try demo.a.?.value_2.append(1);
    try demo.a.?.value_2.append(2);
    try demo.a.?.value_2.append(3);
    try demo.a.?.value_2.append(4);

    const obtained2 = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x10 + 2, 0x04,
        0x01,     0x02,
        0x03,     0x04,
    }, obtained2);
    //const decoded2 = try OneOfDemo.decode(obtained2, testing.allocator);
    //defer decoded2.deinit();
    //try testing.expectEqualSlices(u32, demo.a.?.value_2.items, decoded2.a.?.value_2.items);
}

const MapDemo = struct {
    a_map: AutoHashMap(u64, u64),

    pub const _desc_table = .{
        .a_map = fd(1, .{ .Map = .{
            .key = .{ .t = u64, .pb_data = .{ .Varint = .Simple } },
            .value = .{ .t = u64, .pb_data = .{ .Varint = .Simple } },
        } }),
    };

    pub fn encode(self: MapDemo, allocator: Allocator) ![]u8 {
        return pb_encode(self, allocator);
    }

    pub fn init(allocator: Allocator) MapDemo {
        return pb_init(MapDemo, allocator);
    }

    pub fn deinit(self: MapDemo) void {
        pb_deinit(self);
    }

    pub fn decode(input: []const u8, allocator: Allocator) !MapDemo {
        return pb_decode(MapDemo, input, allocator);
    }
};

test "MapDemo" {
    var demo = MapDemo.init(testing.allocator);
    defer demo.deinit();

    try demo.a_map.put(1, 2);
    try demo.a_map.put(4, 5);

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08 + 2, // tag of a_map
        10, // size of a_map
        4, // size of the first item in a_map
        0x08, // key tag
        0x01, // key value
        0x10, // value tag
        0x02, // value value
        4,
        0x08,
        0x04,
        0x10,
        0x05,
    }, obtained);

    const decoded = try MapDemo.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqual(demo.a_map.get(1), decoded.a_map.get(1));
    try testing.expectEqual(demo.a_map.get(4), decoded.a_map.get(4));
}
