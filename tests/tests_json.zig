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

    try expect(std.meta.eql(test_pb, test_json));
}
