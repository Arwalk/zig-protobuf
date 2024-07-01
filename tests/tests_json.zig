const std = @import("std");
const ArrayList = std.ArrayList;
const json = std.json;

const expect = std.testing.expect;
const ally = std.testing.allocator;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;

const tests = @import("./generated/tests.pb.zig");
const FixedSizes = tests.FixedSizes;
const TopLevelEnum = tests.TopLevelEnum;
const RepeatedEnum = tests.RepeatedEnum;
const WithStrings = tests.WithStrings;
const WithRepeatedStrings = tests.WithRepeatedStrings;
const WithEnum = tests.WithEnum;
const WithSubmessages = tests.WithSubmessages;
const Packed = tests.Packed;

test "test_json_encode_fixedsizes" {
    const test_pb = FixedSizes{
        .sfixed64 = 1,
        .sfixed32 = 2,
        .fixed32 = 3,
        .fixed64 = 4,
        .double = 5.0,
        .float = 6.0,
    };

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(
        u8,
        encoded,
        \\{
        \\  "sfixed64": 1,
        \\  "sfixed32": 2,
        \\  "fixed32": 3,
        \\  "fixed64": 4,
        \\  "double": 5e0,
        \\  "float": 6e0
        \\}
        ,
    ));
}

test "test_json_decode_fixedsizes" {
    const test_pb = FixedSizes{
        .sfixed64 = 1,
        .sfixed32 = 2,
        .fixed32 = 3,
        .fixed64 = 4,
        .double = 5.0,
        .float = 6.0,
    };

    const test_json = try FixedSizes.json_decode(
        \\{
        \\  "sfixed64": 1,
        \\  "sfixed32": 2,
        \\  "fixed32": 3,
        \\  "fixed64": 4,
        \\  "double": 5e0,
        \\  "float": 6e0
        \\}
    ,
        .{},
        ally,
    );
    defer test_json.deinit();

    try expect(std.meta.eql(test_pb, test_json));
}

test "test_json_encode_repeatedenum" {
    var value = ArrayList(TopLevelEnum).init(ally);
    defer value.deinit();

    try value.append(.SE_ZERO);
    try value.append(.SE2_ZERO);

    const test_pb = RepeatedEnum{ .value = value };

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(
        u8,
        encoded,
        \\{
        \\  "value": [
        \\    "SE_ZERO",
        \\    "SE2_ZERO"
        \\  ]
        \\}
        ,
    ));
}

test "test_json_decode_repeatedenum" {
    var value = ArrayList(TopLevelEnum).init(ally);
    defer value.deinit();

    try value.append(.SE_ZERO);
    try value.append(.SE2_ZERO);

    const test_pb = RepeatedEnum{ .value = value };

    // Parsers accept both enum names and integer values
    // https://protobuf.dev/programming-guides/proto3/#json
    for ([_][]const u8{
        \\{
        \\  "value": [
        \\    "SE_ZERO",
        \\    "SE2_ZERO"
        \\  ]
        \\}
        ,
        \\{
        \\  "value": [
        \\    0,
        \\    "SE2_ZERO"
        \\  ]
        \\}
        ,
        \\{
        \\  "value": [
        \\    0,
        \\    3
        \\  ]
        \\}
        ,
    }) |json_string| {
        const test_json = try RepeatedEnum.json_decode(json_string, .{}, ally);
        defer test_json.deinit();

        try expect(std.mem.eql(
            TopLevelEnum,
            test_pb.value.items,
            test_json.value.items,
        ));
    }
}

test "test_json_encode_withstrings" {
    const test_pb = WithStrings{ .name = ManagedString.static("test_string") };

    const encoded = try test_pb.json_encode(.{ .whitespace = .indent_2 }, ally);
    defer ally.free(encoded);

    try expect(std.mem.eql(
        u8,
        encoded,
        \\{
        \\  "name": "test_string"
        \\}
        ,
    ));
}

test "test_json_decode_withstrings" {
    const test_pb = WithStrings{ .name = ManagedString.static("test_string") };

    const test_json = try WithStrings.json_decode(
        \\{
        \\  "name": "test_string"
        \\}
    ,
        .{},
        ally,
    );
    defer test_json.deinit();

    try expect(std.mem.eql(
        u8,
        test_pb.name.getSlice(),
        test_json.name.getSlice(),
    ));
}

test "test_json_encode_withsubmessages" {
    const test_pb = WithSubmessages{ .with_enum = WithEnum{ .value = .A } };

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(
        u8,
        encoded,
        \\{
        \\  "with_enum": {
        \\    "value": "A"
        \\  }
        \\}
        ,
    ));
}

test "test_json_decode_withsubmessages" {
    const test_pb = WithSubmessages{ .with_enum = WithEnum{ .value = .A } };

    const test_json = try WithSubmessages.json_decode(
        \\{
        \\  "with_enum": {
        \\    "value": "A"
        \\  }
        \\}
    ,
        .{},
        ally,
    );
    defer test_json.deinit();

    try expect(std.meta.eql(test_pb, test_json));
}

test "test_json_encode_packed" {
    var test_pb = Packed.init(ally);
    defer test_pb.deinit();

    try test_pb.int32_list.append(-1);
    try test_pb.int32_list.append(2);
    try test_pb.int32_list.append(3);

    try test_pb.uint32_list.append(1);
    try test_pb.uint32_list.append(2);
    try test_pb.uint32_list.append(3);

    try test_pb.sint32_list.append(2);
    try test_pb.sint32_list.append(3);
    try test_pb.sint32_list.append(4);

    try test_pb.float_list.append(1.0);
    try test_pb.float_list.append(-1_000.0);

    try test_pb.double_list.append(2.1);
    try test_pb.double_list.append(-1_000.0);

    try test_pb.int64_list.append(3);
    try test_pb.int64_list.append(-4);
    try test_pb.int64_list.append(5);

    try test_pb.sint64_list.append(-4);
    try test_pb.sint64_list.append(5);
    try test_pb.sint64_list.append(-6);

    try test_pb.uint64_list.append(5);
    try test_pb.uint64_list.append(6);
    try test_pb.uint64_list.append(7);

    try test_pb.bool_list.append(true);
    try test_pb.bool_list.append(false);
    try test_pb.bool_list.append(false);

    try test_pb.enum_list.append(.SE_ZERO);
    try test_pb.enum_list.append(.SE2_ONE);

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(
        u8,
        encoded,
        \\{
        \\  "int32_list": [
        \\    -1,
        \\    2,
        \\    3
        \\  ],
        \\  "uint32_list": [
        \\    1,
        \\    2,
        \\    3
        \\  ],
        \\  "sint32_list": [
        \\    2,
        \\    3,
        \\    4
        \\  ],
        \\  "float_list": [
        \\    1e0,
        \\    -1e3
        \\  ],
        \\  "double_list": [
        \\    2.1e0,
        \\    -1e3
        \\  ],
        \\  "int64_list": [
        \\    3,
        \\    -4,
        \\    5
        \\  ],
        \\  "sint64_list": [
        \\    -4,
        \\    5,
        \\    -6
        \\  ],
        \\  "uint64_list": [
        \\    5,
        \\    6,
        \\    7
        \\  ],
        \\  "bool_list": [
        \\    true,
        \\    false,
        \\    false
        \\  ],
        \\  "enum_list": [
        \\    "SE_ZERO",
        \\    "SE2_ONE"
        \\  ]
        \\}
        ,
    ));
}

test "test_json_decode_packed" {
    var test_pb = Packed.init(ally);
    defer test_pb.deinit();

    try test_pb.int32_list.append(-1);
    try test_pb.int32_list.append(2);
    try test_pb.int32_list.append(3);

    try test_pb.uint32_list.append(1);
    try test_pb.uint32_list.append(2);
    try test_pb.uint32_list.append(3);

    try test_pb.sint32_list.append(2);
    try test_pb.sint32_list.append(3);
    try test_pb.sint32_list.append(4);

    try test_pb.float_list.append(1.0);
    try test_pb.float_list.append(-1_000.0);

    try test_pb.double_list.append(2.1);
    try test_pb.double_list.append(-1_000.0);

    try test_pb.int64_list.append(3);
    try test_pb.int64_list.append(-4);
    try test_pb.int64_list.append(5);

    try test_pb.sint64_list.append(-4);
    try test_pb.sint64_list.append(5);
    try test_pb.sint64_list.append(-6);

    try test_pb.uint64_list.append(5);
    try test_pb.uint64_list.append(6);
    try test_pb.uint64_list.append(7);

    try test_pb.bool_list.append(true);
    try test_pb.bool_list.append(false);
    try test_pb.bool_list.append(false);

    try test_pb.enum_list.append(.SE_ZERO);
    try test_pb.enum_list.append(.SE2_ONE);

    const test_json = try Packed.json_decode(
        \\{
        \\  "int32_list": [
        \\    -1,
        \\    2,
        \\    3
        \\  ],
        \\  "uint32_list": [
        \\    1,
        \\    2,
        \\    3
        \\  ],
        \\  "sint32_list": [
        \\    2,
        \\    3,
        \\    4
        \\  ],
        \\  "float_list": [
        \\    1e0,
        \\    -1e3
        \\  ],
        \\  "double_list": [
        \\    2.1e0,
        \\    -1e3
        \\  ],
        \\  "int64_list": [
        \\    3,
        \\    -4,
        \\    5
        \\  ],
        \\  "sint64_list": [
        \\    -4,
        \\    5,
        \\    -6
        \\  ],
        \\  "uint64_list": [
        \\    5,
        \\    6,
        \\    7
        \\  ],
        \\  "bool_list": [
        \\    true,
        \\    false,
        \\    false
        \\  ],
        \\  "enum_list": [
        \\    "SE_ZERO",
        \\    "SE2_ONE"
        \\  ]
        \\}
    ,
        .{},
        ally,
    );
    defer test_json.deinit();

    inline for (std.meta.fields(Packed)) |structInfo| {
        const test_pb_items = @field(test_pb, structInfo.name).items;
        try expect(std.mem.eql(
            @typeInfo(@TypeOf(test_pb_items)).Pointer.child,
            test_pb_items,
            @field(test_json, structInfo.name).items,
        ));
    }
}
