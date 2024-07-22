const std = @import("std");
const Allocator = std.mem.Allocator;
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
const OneofContainer = @import("./generated/tests/oneof.pb.zig").OneofContainer;

// FixedSizes tests
const fixedsizes_str =
    \\{
    \\  "sfixed64": 1,
    \\  "sfixed32": 2,
    \\  "fixed32": 3,
    \\  "fixed64": 4,
    \\  "double": 5e0,
    \\  "float": 6e0
    \\}
;

fn fixedsizes_test_pb() FixedSizes {
    return FixedSizes{
        .sfixed64 = 1,
        .sfixed32 = 2,
        .fixed32 = 3,
        .fixed64 = 4,
        .double = 5.0,
        .float = 6.0,
    };
}

test "test_json_encode_fixedsizes" {
    const test_pb = fixedsizes_test_pb();

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, fixedsizes_str));
}

test "test_json_decode_fixedsizes" {
    const test_pb = fixedsizes_test_pb();

    const test_json = try FixedSizes.json_decode(fixedsizes_str, .{}, ally);
    defer test_json.deinit();

    try expect(std.meta.eql(test_pb, test_json));
}

// RepeatedEnum tests
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

// WithStrings tests
const withstrings_str =
    \\{
    \\  "name": "test_string"
    \\}
;

fn withstrings_test_pb() WithStrings {
    return WithStrings{ .name = ManagedString.static("test_string") };
}

test "test_json_encode_withstrings" {
    const test_pb = withstrings_test_pb();

    const encoded = try test_pb.json_encode(.{ .whitespace = .indent_2 }, ally);
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, withstrings_str));
}

test "test_json_decode_withstrings" {
    const test_pb = withstrings_test_pb();

    const test_json = try WithStrings.json_decode(withstrings_str, .{}, ally);
    defer test_json.deinit();

    try expect(std.mem.eql(
        u8,
        test_pb.name.getSlice(),
        test_json.name.getSlice(),
    ));
}

// WithSubmessages tests
const withsubmessages_str =
    \\{
    \\  "with_enum": {
    \\    "value": "A"
    \\  }
    \\}
;

fn withsubmessages_test_pb() WithSubmessages {
    return WithSubmessages{ .with_enum = WithEnum{ .value = .A } };
}

test "test_json_encode_withsubmessages" {
    const test_pb = withsubmessages_test_pb();

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, withsubmessages_str));
}

test "test_json_decode_withsubmessages" {
    const test_pb = withsubmessages_test_pb();

    const test_json = try WithSubmessages.json_decode(withsubmessages_str, .{}, ally);
    defer test_json.deinit();

    try expect(std.meta.eql(test_pb, test_json));
}

// Packed tests
const packed_str =
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
;

fn packed_test_pb(allocator: Allocator) !Packed {
    var test_pb = Packed.init(allocator);

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

    return test_pb;
}

test "test_json_encode_packed" {
    const test_pb = try packed_test_pb(ally);
    defer test_pb.deinit();

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, packed_str));
}

test "test_json_decode_packed" {
    const test_pb = try packed_test_pb(ally);
    defer test_pb.deinit();

    const test_json = try Packed.json_decode(packed_str, .{}, ally);
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

const oneofcontainer_oneof_string_in_oneof_str =
    \\{
    \\  "regular_field": "this field is always the same",
    \\  "enum_field": "SOMETHING",
    \\  "some_oneof": {
    \\    "string_in_oneof": "testing oneof field being the string"
    \\  }
    \\}
;

fn oneofcontainer_oneof_string_in_oneof_test_pb() !OneofContainer {
    return OneofContainer{
        .some_oneof = .{ .string_in_oneof = ManagedString.static(
            "testing oneof field being the string",
        ) },
        .regular_field = ManagedString.static("this field is always the same"),
        .enum_field = .SOMETHING,
    };
}

const oneofcontainer_oneof_message_in_oneof_str =
    \\{
    \\  "regular_field": "this field is always the same",
    \\  "enum_field": "UNSPECIFIED",
    \\  "some_oneof": {
    \\    "message_in_oneof": {
    \\      "value": -17,
    \\      "str": "that's a string inside message_in_oneof"
    \\    }
    \\  }
    \\}
;

fn oneofcontainer_oneof_message_in_oneof_test_pb() !OneofContainer {
    return OneofContainer{
        .some_oneof = .{ .message_in_oneof = .{
            .value = -17,
            .str = ManagedString.static(
                "that's a string inside message_in_oneof",
            ),
        } },
        .regular_field = ManagedString.static("this field is always the same"),
        .enum_field = .UNSPECIFIED,
    };
}

test "test_json_encode_oneofcontainer_oneof_string_in_oneof" {
    const test_pb = try oneofcontainer_oneof_string_in_oneof_test_pb();

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, oneofcontainer_oneof_string_in_oneof_str));
}

test "test_json_decode_oneofcontainer_oneof_string_in_oneof" {
    const test_pb = try oneofcontainer_oneof_string_in_oneof_test_pb();

    const test_json = try OneofContainer.json_decode(
        oneofcontainer_oneof_string_in_oneof_str,
        .{},
        ally,
    );
    defer test_json.deinit();

    // TODO(libro): Make some alternative to std.meta.eql to
    //   effectively compare two generated struct instances
    //   which would handle ManagedStrings etc.
    try expect(std.mem.eql(
        u8,
        test_pb.regular_field.getSlice(),
        test_json.regular_field.getSlice(),
    ));
    try expect(test_pb.enum_field == test_json.enum_field);
    try expect(std.mem.eql(
        u8,
        test_pb.some_oneof.?.string_in_oneof.getSlice(),
        test_json.some_oneof.?.string_in_oneof.getSlice(),
    ));
}

test "test_json_encode_oneofcontainer_oneof_message_in_oneof" {
    const test_pb = try oneofcontainer_oneof_message_in_oneof_test_pb();

    const encoded = try test_pb.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(std.mem.eql(u8, encoded, oneofcontainer_oneof_message_in_oneof_str));
}

test "test_json_decode_oneofcontainer_oneof_message_in_oneof" {
    const test_pb = try oneofcontainer_oneof_message_in_oneof_test_pb();

    const test_json = try OneofContainer.json_decode(
        oneofcontainer_oneof_message_in_oneof_str,
        .{},
        ally,
    );
    defer test_json.deinit();

    try expect(std.mem.eql(
        u8,
        test_pb.regular_field.getSlice(),
        test_json.regular_field.getSlice(),
    ));
    try expect(test_pb.enum_field == test_json.enum_field);
    try expect(test_pb.some_oneof.?.message_in_oneof.value == test_json.some_oneof.?.message_in_oneof.value);
    try expect(std.mem.eql(
        u8,
        test_pb.some_oneof.?.message_in_oneof.str.getSlice(),
        test_json.some_oneof.?.message_in_oneof.str.getSlice(),
    ));
}
