const std = @import("std");
const ArrayList = std.ArrayList;
const json = std.json;

const tests = @import("./generated/tests.pb.zig");
const FixedSizes = tests.FixedSizes;
const TopLevelEnum = tests.TopLevelEnum;
const RepeatedEnum = tests.RepeatedEnum;

test "test_json_encode_fixedsizes" {
    const test_pb = FixedSizes{
        .sfixed64 = 1,
        .sfixed32 = 2,
        .fixed32 = 3,
        .fixed64 = 4,
        .double = 5.0,
        .float = 6.0,
    };

    const ally = std.testing.allocator;
    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try std.testing.expect(std.mem.eql(
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

    const ally = std.testing.allocator;
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

    try std.testing.expect(std.meta.eql(test_pb, test_json));
}

test "test_json_encode_repeatedenum" {
    const ally = std.testing.allocator;

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

    try std.testing.expect(std.mem.eql(
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
    const ally = std.testing.allocator;

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

        try std.testing.expect(std.mem.eql(
            TopLevelEnum,
            test_pb.value.items,
            test_json.value.items,
        ));
    }
}
