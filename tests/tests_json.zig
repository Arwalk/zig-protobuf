const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const allocator = std.testing.allocator;

const protobuf = @import("protobuf");

// TODO(libro): Also need to check if JSON string snake_case field
//   names will be decoded correctly (parser should handle
//   both camelCase and snake_case variants)

fn _compare_numerics(value1: anytype, value2: @TypeOf(value1)) bool {
    switch (@typeInfo(@TypeOf(value1))) {
        .int, .comptime_int, .@"enum", .bool => {
            return value1 == value2;
        },
        .float, .comptime_float => {
            if (std.math.isNan(value1)) {
                return std.math.isNan(value2);
            }
            if (std.math.isPositiveInf(value1)) {
                return std.math.isPositiveInf(value2);
            }
            if (std.math.isNegativeInf(value1)) {
                return std.math.isNegativeInf(value2);
            }
            return value1 == value2;
        },
        else => unreachable,
    }
}

fn compare_pb_structs(value1: anytype, value2: @TypeOf(value1)) bool {
    const T = @TypeOf(value1);
    inline for (std.meta.fields(T)) |structInfo| {
        const field_type = @TypeOf(@field(value1, structInfo.name));

        var field1: switch (@typeInfo(field_type)) {
            .optional => |optional| optional.child,
            else => field_type,
        } = undefined;
        var field2: @TypeOf(field1) = undefined;

        // If this variable will stay null after next switch statement than:
        //   1. It was non-optional field
        //   2. Field is optional, both field are
        //        not null and thus further check are
        //        requied (for those .? is applied)
        var are_optionals_equal: ?bool = null;
        switch (@typeInfo(field_type)) {
            .optional => {
                if (@field(
                    value1,
                    structInfo.name,
                ) == null and @field(
                    value2,
                    structInfo.name,
                ) == null) {
                    // Both field are nulls, so they're
                    // passing the equality check
                    are_optionals_equal = true;
                } else if (@field(
                    value1,
                    structInfo.name,
                ) == null or @field(
                    value2,
                    structInfo.name,
                ) == null) {
                    // One optional field is null while other one
                    // is not - equality check definitely failed here
                    are_optionals_equal = false;
                } else {
                    field1 = @field(value1, structInfo.name).?;
                    field2 = @field(value2, structInfo.name).?;
                }
            },
            else => {
                field1 = @field(value1, structInfo.name);
                field2 = @field(value2, structInfo.name);
            },
        }

        if (are_optionals_equal != null) {
            if (!are_optionals_equal.?) return false;
        } else switch (@field(T._desc_table, structInfo.name).ftype) {
            .repeated, .packed_repeated => |repeated| {
                if (field1.items.len != field2.items.len) return false;
                for (field1.items, field2.items) |array1_el, array2_el| {
                    if (!switch (repeated) {
                        .scalar => |scalar| switch (scalar) {
                            .string, .bytes => std.mem.eql(u8, array1_el, array2_el),
                            else => _compare_numerics(array1_el, array2_el),
                        },
                        .@"enum" => _compare_numerics(array1_el, array2_el),
                        .submessage => compare_pb_structs(array1_el, array2_el),
                    }) return false;
                }
            },
            .oneof => {
                const union_info = switch (@typeInfo(@TypeOf(field1))) {
                    .@"union" => |u| u,
                    else => @compileError("Oneof should have .@\"union\" type"),
                };
                if (union_info.tag_type == null) {
                    @compileError("There should be no such thing as untagged unions");
                }

                const union1_active_tag = std.meta.activeTag(field1);
                const union2_active_tag = std.meta.activeTag(field2);
                if (union1_active_tag != union2_active_tag) return false;

                inline for (union_info.fields) |field_info| {
                    if (@field(
                        union_info.tag_type.?,
                        field_info.name,
                    ) == union1_active_tag) {
                        if (!switch (@field(
                            @TypeOf(field1)._desc_table,
                            field_info.name,
                        ).ftype) {
                            .scalar => |scalar| switch (scalar) {
                                .string, .bytes => std.mem.eql(
                                    u8,
                                    @field(field1, field_info.name),
                                    @field(field2, field_info.name),
                                ),
                                else => _compare_numerics(
                                    @field(field1, field_info.name),
                                    @field(field2, field_info.name),
                                ),
                            },
                            .@"enum" => _compare_numerics(
                                @field(field1, field_info.name),
                                @field(field2, field_info.name),
                            ),
                            .submessage => compare_pb_structs(
                                @field(field1, field_info.name),
                                @field(field2, field_info.name),
                            ),
                            else => unreachable,
                        }) return false;
                    }
                }
            },
            .submessage => {
                if (!compare_pb_structs(field1, field2)) return false;
            },
            .@"enum" => {
                if (!_compare_numerics(field1, field2)) return false;
            },
            .scalar => |scalar| switch (scalar) {
                .string, .bytes => {
                    if (!std.mem.eql(u8, field1, field2)) return false;
                },
                else => {
                    if (!_compare_numerics(field1, field2)) return false;
                },
            },
        }
    }
    return true;
}

fn compare_pb_jsons(encoded: []const u8, expected: []const u8) bool {
    const are_jsons_equal = std.mem.eql(u8, encoded, expected);
    if (!are_jsons_equal) {
        std.debug.print(
            \\fail:
            \\JSON strings mismatch:
            \\- (encoded) ----------
            \\{s}
            \\- (expected) ---------
            \\{s}
            \\----------------------
            \\
        , .{ encoded, expected });
    }
    return are_jsons_equal;
}

// FixedSizes tests
const fixed_sizes_init = @import("./json_data/fixed_sizes/instance.zig").get;
const fixed_sizes_camel_case_json = @embedFile("./json_data/fixed_sizes/camelCase.json");
const fixed_sizes_camel_case_1_json = @embedFile("./json_data/fixed_sizes/camelCase_1.json");
const fixed_sizes_camel_case_2_json = @embedFile("./json_data/fixed_sizes/camelCase_2.json");
const fixed_sizes_camel_case_3_json = @embedFile("./json_data/fixed_sizes/camelCase_3.json");

test "JSON: encode FixedSizes" {
    const pb_instance = fixed_sizes_init();
    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, fixed_sizes_camel_case_json));
}

test "JSON: decode FixedSizes (camelCase)" {
    const pb_instance = fixed_sizes_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        fixed_sizes_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode FixedSizes (from string 1)" {
    const pb_instance = fixed_sizes_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        fixed_sizes_camel_case_1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode FixedSizes (from string 2)" {
    const pb_instance = fixed_sizes_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        fixed_sizes_camel_case_2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode FixedSizes (from string 3)" {
    const pb_instance = fixed_sizes_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        fixed_sizes_camel_case_3_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// RepeatedEnum tests
const repeated_enum_init = @import("./json_data/repeated_enum/instance.zig").get;

// Parsers accept both enum names and integer values
// https://protobuf.dev/programming-guides/proto3/#json
const repeated_enum_camel_case1_json = @embedFile(
    "./json_data/repeated_enum/camelCase1.json",
);
const repeated_enum_camel_case2_json = @embedFile(
    "./json_data/repeated_enum/camelCase2.json",
);
const repeated_enum_camel_case3_json = @embedFile(
    "./json_data/repeated_enum/camelCase3.json",
);

test "JSON: encode RepeatedEnum" {
    var pb_instance = try repeated_enum_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, repeated_enum_camel_case1_json));
}

test "JSON: decode RepeatedEnum (camelCase, variant 1)" {
    var pb_instance = try repeated_enum_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        repeated_enum_camel_case1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode RepeatedEnum (camelCase, variant 2)" {
    var pb_instance = try repeated_enum_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        repeated_enum_camel_case2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode RepeatedEnum (camelCase, variant 3)" {
    var pb_instance = try repeated_enum_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        repeated_enum_camel_case3_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// WithStrings tests
const with_strings_init = @import("./json_data/with_strings/instance.zig").get;
const with_strings_camel_case_json = @embedFile("./json_data/with_strings/camelCase.json");

test "JSON: encode WithStrings" {
    var pb_instance = try with_strings_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, with_strings_camel_case_json));
}

test "JSON: decode WithStrings" {
    var pb_instance = try with_strings_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        with_strings_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// WithSubmessages tests
const with_submessages_init = @import(
    "./json_data/with_submessages/instance.zig",
).get;
const with_submessages_camel_case_json = @embedFile(
    "./json_data/with_submessages/camelCase.json",
);
const with_submessages_camel_case_enum_as_integer_json = @embedFile(
    "./json_data/with_submessages/camelCase_enum_as_integer.json",
);
const with_submessages_snake_case_json = @embedFile(
    "./json_data/with_submessages/snake_case.json",
);

test "JSON: encode WithSubmessages" {
    const pb_instance = with_submessages_init();
    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, with_submessages_camel_case_json));
}

test "JSON: decode WithSubmessages (from camelCase)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        with_submessages_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode WithSubmessages (from camelCase, enum as integer)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        with_submessages_camel_case_enum_as_integer_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode WithSubmessages (from snake_case)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        with_submessages_snake_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// -----------
// Packed test
// -----------
const packed_init = @import("./json_data/packed/instance.zig").get;
const packed_init2 = @import("./json_data/packed/instance.zig").get2;
const packed_camel_case_json = @embedFile("./json_data/packed/camelCase.json");
const packed_snake_case_json = @embedFile("./json_data/packed/snake_case.json");
const packed_mixed_case_json = @embedFile("./json_data/packed/mixed_case.json");
const packed_camel_case_1_json = @embedFile("./json_data/packed/camelCase_1.json");

test "JSON: encode Packed" {
    var pb_instance = try packed_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, packed_camel_case_json));
}

test "JSON: decode Packed (from camelCase)" {
    var pb_instance = try packed_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        packed_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Packed (from snake_case)" {
    var pb_instance = try packed_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        packed_snake_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Packed (from mixed_case)" {
    var pb_instance = try packed_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        packed_mixed_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Packed (from stringified float/integers)" {
    var pb_instance = try packed_init2(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        packed_camel_case_1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// ------------------------------------------------
// OneofContainer test (some_oneof=string_in_oneof)
// ------------------------------------------------
const string_in_oneof_init = @import(
    "./json_data/oneof_container/string_in_oneof_instance.zig",
).get;
const string_in_oneof_camel_case_json = @embedFile(
    "./json_data/oneof_container/string_in_oneof_camelCase.json",
);
const string_in_oneof_snake_case_json = @embedFile(
    "./json_data/oneof_container/string_in_oneof_snake_case.json",
);
const string_in_oneof_mixed_case1_json = @embedFile(
    "./json_data/oneof_container/string_in_oneof_mixed_case1.json",
);
const string_in_oneof_mixed_case2_json = @embedFile(
    "./json_data/oneof_container/string_in_oneof_mixed_case2.json",
);

test "JSON: encode OneofContainer (string_in_oneof)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, string_in_oneof_camel_case_json));
}

test "JSON: decode OneofContainer (string_in_oneof) (from camelCase)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        string_in_oneof_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from snake_case)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        string_in_oneof_snake_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from mixed_case1)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        string_in_oneof_mixed_case1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from mixed_case2)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        string_in_oneof_mixed_case2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// ------------------------------------------------
// OneofContainer test (some_oneof=message_in_oneof)
// ------------------------------------------------
const message_in_oneof_init = @import(
    "./json_data/oneof_container/message_in_oneof_instance.zig",
).get;
const message_in_oneof_camel_case_json = @embedFile(
    "./json_data/oneof_container/message_in_oneof_camelCase.json",
);
const message_in_oneof_snake_case_json = @embedFile(
    "./json_data/oneof_container/message_in_oneof_snake_case.json",
);
const message_in_oneof_mixed_case1_json = @embedFile(
    "./json_data/oneof_container/message_in_oneof_mixed_case1.json",
);
const message_in_oneof_mixed_case2_json = @embedFile(
    "./json_data/oneof_container/message_in_oneof_mixed_case2.json",
);

test "JSON: encode OneofContainer (message_in_oneof)" {
    var pb_instance = try message_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, message_in_oneof_camel_case_json));
}

test "JSON: decode OneofContainer (message_in_oneof) (from camelCase)" {
    var pb_instance = try message_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        message_in_oneof_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from snake_case)" {
    var pb_instance = try message_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        message_in_oneof_snake_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from mixed_case1)" {
    var pb_instance = try message_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        message_in_oneof_mixed_case1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from mixed_case2)" {
    var pb_instance = try message_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        message_in_oneof_mixed_case2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// --------------
// WithBytes test
// --------------
const bytes_init = @import("./json_data/with_bytes/instance.zig").get;
const bytes_camel_case_json = @embedFile("json_data/with_bytes/camelCase.json");
const bytes_snake_case_json = @embedFile("json_data/with_bytes/snake_case.json");

test "JSON: encode Bytes" {
    var pb_instance = try bytes_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, bytes_camel_case_json));
}

test "JSON: decode Bytes (from camelCase)" {
    var pb_instance = try bytes_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        bytes_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Bytes (from snake_case)" {
    var pb_instance = try bytes_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        bytes_snake_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// --------------
// MoreBytes test
// --------------
const more_bytes_init = @import("./json_data/more_bytes/instance.zig").get;
const more_bytes_camel_case_json = @embedFile("./json_data/more_bytes/camelCase.json");

test "JSON: encode MoreBytes" {
    var pb_instance = try more_bytes_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, more_bytes_camel_case_json));
}

test "JSON: decode MoreBytes (from camelCase)" {
    var pb_instance = try more_bytes_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        more_bytes_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// -----------
// Value tests
// -----------
const value_inits = @import("./json_data/value/instance.zig");
const value_camel_case1_json = @embedFile("./json_data/value/camelCase1.json");
const value_camel_case2_json = @embedFile("./json_data/value/camelCase2.json");
const value_camel_case3_json = @embedFile("./json_data/value/camelCase3.json");
const value_camel_case4_json = @embedFile("./json_data/value/camelCase4.json");
const value_camel_case4_1_json = @embedFile("./json_data/value/camelCase4_1.json");
const value_camel_case4_2_json = @embedFile("./json_data/value/camelCase4_2.json");
const value_camel_case4_3_json = @embedFile("./json_data/value/camelCase4_3.json");
const value_camel_case4_4_json = @embedFile("./json_data/value/camelCase4_4.json");
const value_camel_case4_5_json = @embedFile("./json_data/value/camelCase4_5.json");
const value_camel_case4_6_json = @embedFile("./json_data/value/camelCase4_6.json");

test "JSON: encode Value (.number_value=NaN) rejects" {
    // Proto3 spec: NaN is not representable in JSON for google.protobuf.Value
    const pb_instance = value_inits.get1();
    const result = pb_instance.jsonEncode(.{ .whitespace = .indent_2 }, .{}, allocator);
    try std.testing.expectError(error.RangeError, result);
}

test "JSON: encode Value (.number_value=-Infinity) rejects" {
    // Proto3 spec: Infinity is not representable in JSON for google.protobuf.Value
    const pb_instance = value_inits.get2();
    const result = pb_instance.jsonEncode(.{ .whitespace = .indent_2 }, .{}, allocator);
    try std.testing.expectError(error.RangeError, result);
}

test "JSON: encode Value (.number_value=Infinity) rejects" {
    // Proto3 spec: Infinity is not representable in JSON for google.protobuf.Value
    const pb_instance = value_inits.get3();
    const result = pb_instance.jsonEncode(.{ .whitespace = .indent_2 }, .{}, allocator);
    try std.testing.expectError(error.RangeError, result);
}

test "JSON: encode Value (.number_value=1.0)" {
    const pb_instance = value_inits.get4();

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, value_camel_case4_json));
}

test "JSON: decode Value (.number_value=NaN)" {
    const pb_instance = value_inits.get1();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=-Infinity)" {
    const pb_instance = value_inits.get2();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=Infinity)" {
    const pb_instance = value_inits.get3();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case3_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 1)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_1_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 2)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_2_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 3)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_3_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 4)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_4_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 5)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_5_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Value (.number_value=1.0, from string 6)" {
    const pb_instance = value_inits.get4();

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        value_camel_case4_6_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// ----------------
// TestOneof2 tests
// ----------------
const test_oneof2_init = @import("./json_data/test_oneof2/instance.zig").get;
const test_oneof2_camel_case_json = @embedFile("./json_data/test_oneof2/camelCase.json");

test "JSON: encode TestOneof2 (oneof=.Bytes)" {
    var pb_instance = try test_oneof2_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, test_oneof2_camel_case_json));
}

test "JSON: decode TestOneof2 (oneof=.Bytes)" {
    var pb_instance = try test_oneof2_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        test_oneof2_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// ---------------------
// TestPackedTypes tests
// ---------------------
const test_packed_types_init = @import(
    "./json_data/test_packed_types/instance.zig",
).get;
const test_packed_types_camel_case_json = @embedFile(
    "./json_data/test_packed_types/camelCase.json",
);

test "JSON: encode TestPackedTypes (repeated NaNs/infs)" {
    var pb_instance = try test_packed_types_init(allocator);
    defer pb_instance.deinit(allocator);

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        .{},
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, test_packed_types_camel_case_json));
}

test "JSON: decode TestPackedTypes (repeated NaNs/infs)" {
    var pb_instance = try test_packed_types_init(allocator);
    defer pb_instance.deinit(allocator);

    const decoded = try @TypeOf(pb_instance).jsonDecode(
        test_packed_types_camel_case_json,
        .{},
        allocator,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode selfref structs" {
    // TODO
}

test "JSON: encode selfref structs" {
    // TODO
}

// OneofContainer flat-format (issue #147) tests
const oneof_zig = @import("./generated/tests/oneof.pb.zig");
const OneofContainer = oneof_zig.OneofContainer;

test "JSON: encode oneof flat format (emit_oneof_field_name=false)" {
    const msg = OneofContainer{
        .regular_field = "hello",
        .some_oneof = .{ .string_in_oneof = "world" },
    };
    const encoded = try msg.jsonEncode(.{}, .{ .emit_oneof_field_name = false }, allocator);
    defer allocator.free(encoded);
    // enumField is UNSPECIFIED (default enum value) so it is omitted
    try std.testing.expectEqualStrings(
        \\{"regularField":"hello","stringInOneof":"world"}
    , encoded);
}

test "JSON: encode oneof legacy wrapped format (emit_oneof_field_name=true)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);
    // Default jsonEncode uses wrapped format (backward compat)
    // enumField is UNSPECIFIED (default enum value) so it is omitted
    const encoded = try pb_instance.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(
        \\{"regularField":"this field is always the same","someOneof":{"stringInOneof":"testing oneof field being the string"}}
    , encoded);
}

test "JSON: decode oneof flat format (variant key directly in parent)" {
    // Flat format: variant name at top level, no "someOneof" wrapper
    const json_str =
        \\{"regularField":"hello","stringInOneof":"world"}
    ;
    const result = try std.json.parseFromSlice(
        OneofContainer,
        allocator,
        json_str,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.value.regular_field);
    try expect(result.value.some_oneof != null);
    try std.testing.expectEqualStrings("world", result.value.some_oneof.?.string_in_oneof);
}

test "JSON: decode oneof flat format with camelCase variant name" {
    const json_str =
        \\{"stringInOneof":"camelTest"}
    ;
    const result = try std.json.parseFromSlice(
        OneofContainer,
        allocator,
        json_str,
        .{},
    );
    defer result.deinit();
    try expect(result.value.some_oneof != null);
    try std.testing.expectEqualStrings("camelTest", result.value.some_oneof.?.string_in_oneof);
}

test "JSON: decode oneof flat format with snake_case variant name" {
    const json_str =
        \\{"string_in_oneof":"snake_test"}
    ;
    const result = try std.json.parseFromSlice(
        OneofContainer,
        allocator,
        json_str,
        .{},
    );
    defer result.deinit();
    try expect(result.value.some_oneof != null);
    try std.testing.expectEqualStrings("snake_test", result.value.some_oneof.?.string_in_oneof);
}

test "JSON: roundtrip oneof flat format" {
    const original = OneofContainer{
        .regular_field = "roundtrip",
        .some_oneof = .{ .string_in_oneof = "value" },
    };
    const encoded = try original.jsonEncode(.{}, .{ .emit_oneof_field_name = false }, allocator);
    defer allocator.free(encoded);

    // enumField is UNSPECIFIED (default enum value) so it is omitted
    try std.testing.expectEqualStrings(
        \\{"regularField":"roundtrip","stringInOneof":"value"}
    , encoded);

    // Decode flat format
    const result = try std.json.parseFromSlice(
        OneofContainer,
        allocator,
        encoded,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(original.regular_field, result.value.regular_field);
    try expect(result.value.some_oneof != null);
    try std.testing.expectEqualStrings(
        original.some_oneof.?.string_in_oneof,
        result.value.some_oneof.?.string_in_oneof,
    );
}

// =============================================================================
// Map JSON encoding/decoding tests (Issue #59)
//
// Protobuf JSON spec requires map fields to serialize as JSON objects
// rather than arrays of entry objects.
// =============================================================================

const graphics = @import("./generated/graphics.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const Index = graphics.Index;
const Npc = graphics.Npc;
const TestAllTypesProto3 = proto3.TestAllTypesProto3;

// --- Encoding tests ---

test "JSON map: encode map<string, int32> as JSON object" {
    var idx = Index{};
    try idx.animations.append(allocator, .{ .key = "walk", .value = 1 });
    try idx.animations.append(allocator, .{ .key = "run", .value = 2 });
    defer idx.animations.deinit(allocator);

    const encoded = try idx.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Should contain an "animations" field that is a JSON object, not an array
    const animations = root.get("animations").?;
    try expect(animations == .object);
    // Should have walk=1 and run=2
    try expect(animations.object.get("walk").?.integer == 1);
    try expect(animations.object.get("run").?.integer == 2);
    try expect(animations.object.count() == 2);
    // Should NOT contain the old array-of-entries format (no "key" field at root level)
    try expect(root.get("key") == null);
}

test "JSON map: encode map<int32, int32> with stringified keys" {
    var npc = Npc{};
    try npc.skills.append(allocator, .{ .key = 42, .value = 100 });
    try npc.skills.append(allocator, .{ .key = 7, .value = 50 });
    defer npc.skills.deinit(allocator);

    const encoded = try npc.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Integer keys must be stringified in JSON
    const skills = root.get("skills").?;
    try expect(skills == .object);
    try expect(skills.object.get("42").?.integer == 100);
    try expect(skills.object.get("7").?.integer == 50);
    try expect(skills.object.count() == 2);
}

test "JSON map: encode map<bool, bool> with stringified keys" {
    var msg = TestAllTypesProto3{};
    try msg.map_bool_bool.append(allocator, .{ .key = true, .value = false });
    try msg.map_bool_bool.append(allocator, .{ .key = false, .value = true });
    defer msg.map_bool_bool.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapBoolBool").?;
    try expect(map == .object);
    try expect(map.object.get("true").?.bool == false);
    try expect(map.object.get("false").?.bool == true);
    try expect(map.object.count() == 2);
}

test "JSON map: encode map<string, string>" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_string.append(allocator, .{ .key = "hello", .value = "world" });
    defer msg.map_string_string.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapStringString").?;
    try expect(map == .object);
    try expectEqualSlices(u8, "world", map.object.get("hello").?.string);
    try expect(map.object.count() == 1);
}

test "JSON map: encode map<int64, int64> with large keys" {
    var msg = TestAllTypesProto3{};
    try msg.map_int64_int64.append(allocator, .{ .key = 9223372036854775807, .value = 42 });
    defer msg.map_int64_int64.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapInt64Int64").?;
    try expect(map == .object);
    // int64 values are encoded as quoted strings per proto JSON spec
    try expectEqualSlices(u8, "42", map.object.get("9223372036854775807").?.string);
    try expect(map.object.count() == 1);
}

test "JSON map: encode map<string, NestedEnum> (enum values)" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_enum.append(allocator, .{ .key = "foo", .value = .BAR });
    defer msg.map_string_nested_enum.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapStringNestedEnum").?;
    try expect(map == .object);
    // Enums are encoded as string names in protobuf JSON
    try expectEqualSlices(u8, "BAR", map.object.get("foo").?.string);
    try expect(map.object.count() == 1);
}

test "JSON map: encode map<string, NestedMessage> (submessage values)" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_message.append(allocator, .{
        .key = "bar",
        .value = .{ .a = 99 },
    });
    defer msg.map_string_nested_message.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapStringNestedMessage").?;
    try expect(map == .object);
    const bar = map.object.get("bar").?;
    try expect(bar == .object);
    try expect(bar.object.get("a").?.integer == 99);
}

test "JSON map: empty map omitted by default, emits {} when emit_default_values is true" {
    const msg = TestAllTypesProto3{};

    // Default: empty map field is omitted entirely (proto3 default suppression)
    const encoded_default = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded_default);
    const parsed_default = try std.json.parseFromSlice(std.json.Value, allocator, encoded_default, .{});
    defer parsed_default.deinit();
    try expect(parsed_default.value.object.get("mapInt32Int32") == null);

    // With emit_default_values: empty map emits as empty object {}
    const encoded_explicit = try msg.jsonEncode(.{}, .{ .emit_default_values = true }, allocator);
    defer allocator.free(encoded_explicit);
    const parsed_explicit = try std.json.parseFromSlice(std.json.Value, allocator, encoded_explicit, .{});
    defer parsed_explicit.deinit();
    const map_field = parsed_explicit.value.object.get("mapInt32Int32").?;
    try expect(map_field == .object);
    try expect(map_field.object.count() == 0);
}

test "JSON: emit_default_values=true preserves all fields including defaults" {
    const msg = TestAllTypesProto3{};

    const encoded = try msg.jsonEncode(.{}, .{ .emit_default_values = true }, allocator);
    defer allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Scalar defaults present
    try expect(root.get("optionalInt32").?.integer == 0);
    try expect(root.get("optionalBool").?.bool == false);
    try expectEqualSlices(u8, "", root.get("optionalString").?.string);
    // Enum default present (ordinal 0 = FOO)
    try expectEqualSlices(u8, "FOO", root.get("optionalNestedEnum").?.string);
    // Empty repeated field present as empty array
    try expect(root.get("repeatedInt32").?.array.items.len == 0);
    // Empty map present as empty object
    try expect(root.get("mapStringString").?.object.count() == 0);
}

test "JSON: default values omitted with default options" {
    const msg = TestAllTypesProto3{};

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // All default-valued fields should be absent
    try expect(root.get("optionalInt32") == null);
    try expect(root.get("optionalBool") == null);
    try expect(root.get("optionalString") == null);
    try expect(root.get("optionalNestedEnum") == null);
    try expect(root.get("repeatedInt32") == null);
    try expect(root.get("mapStringString") == null);
}

// --- Decoding tests ---

test "JSON map: decode map<string, int32> from JSON object" {
    const json_str =
        \\{"animations":{"walk":1,"run":2}}
    ;
    const result = try Index.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.animations.items.len == 2);

    // Check entries (order may vary, but since we're parsing in order it should be walk, run)
    const e0 = result.value.animations.items[0];
    const e1 = result.value.animations.items[1];
    try expectEqualSlices(u8, "walk", e0.key);
    try expect(e0.value == 1);
    try expectEqualSlices(u8, "run", e1.key);
    try expect(e1.value == 2);
}

test "JSON map: decode map<int32, int32> with stringified keys" {
    const json_str =
        \\{"skills":{"42":100,"7":50}}
    ;
    const result = try Npc.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.skills.items.len == 2);
    const e0 = result.value.skills.items[0];
    const e1 = result.value.skills.items[1];
    try expect(e0.key == 42);
    try expect(e0.value == 100);
    try expect(e1.key == 7);
    try expect(e1.value == 50);
}

test "JSON map: decode map<bool, bool>" {
    const json_str =
        \\{"mapBoolBool":{"true":false,"false":true}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_bool_bool.items.len == 2);
    const e0 = result.value.map_bool_bool.items[0];
    const e1 = result.value.map_bool_bool.items[1];
    try expect(e0.key == true);
    try expect(e0.value == false);
    try expect(e1.key == false);
    try expect(e1.value == true);
}

test "JSON map: decode map<string, string>" {
    const json_str =
        \\{"mapStringString":{"hello":"world","foo":"bar"}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_string_string.items.len == 2);
    try expectEqualSlices(u8, "hello", result.value.map_string_string.items[0].key);
    try expectEqualSlices(u8, "world", result.value.map_string_string.items[0].value);
}

test "JSON map: decode empty JSON object as empty map" {
    const json_str =
        \\{"mapInt32Int32":{}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_int32_int32.items.len == 0);
}

test "JSON map: decode map<string, NestedMessage>" {
    const json_str =
        \\{"mapStringNestedMessage":{"bar":{"a":99}}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_string_nested_message.items.len == 1);
    const entry = result.value.map_string_nested_message.items[0];
    try expectEqualSlices(u8, "bar", entry.key);
    try expect(entry.value != null);
    try expect(entry.value.?.a == 99);
}

test "JSON map: decode map<string, NestedEnum>" {
    const json_str =
        \\{"mapStringNestedEnum":{"foo":1}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_string_nested_enum.items.len == 1);
    try expectEqualSlices(u8, "foo", result.value.map_string_nested_enum.items[0].key);
    try expect(result.value.map_string_nested_enum.items[0].value == .BAR);
}

// --- Roundtrip tests ---

test "JSON map: roundtrip map<string, int32>" {
    var idx = Index{};
    try idx.animations.append(allocator, .{ .key = "walk", .value = 1 });
    try idx.animations.append(allocator, .{ .key = "run", .value = 2 });
    defer idx.animations.deinit(allocator);

    const encoded = try idx.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try Index.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.animations.items.len == 2);
    try expectEqualSlices(u8, "walk", decoded.value.animations.items[0].key);
    try expect(decoded.value.animations.items[0].value == 1);
    try expectEqualSlices(u8, "run", decoded.value.animations.items[1].key);
    try expect(decoded.value.animations.items[1].value == 2);
}

test "JSON map: roundtrip map<int32, int32>" {
    var npc = Npc{};
    try npc.skills.append(allocator, .{ .key = 42, .value = 100 });
    defer npc.skills.deinit(allocator);

    const encoded = try npc.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try Npc.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.skills.items.len == 1);
    try expect(decoded.value.skills.items[0].key == 42);
    try expect(decoded.value.skills.items[0].value == 100);
}

test "JSON map: roundtrip map<string, NestedMessage>" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_message.append(allocator, .{
        .key = "first",
        .value = .{ .a = 10 },
    });
    try msg.map_string_nested_message.append(allocator, .{
        .key = "second",
        .value = .{ .a = 20 },
    });
    defer msg.map_string_nested_message.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_string_nested_message.items.len == 2);
    try expectEqualSlices(u8, "first", decoded.value.map_string_nested_message.items[0].key);
    try expect(decoded.value.map_string_nested_message.items[0].value.?.a == 10);
    try expectEqualSlices(u8, "second", decoded.value.map_string_nested_message.items[1].key);
    try expect(decoded.value.map_string_nested_message.items[1].value.?.a == 20);
}

test "JSON map: roundtrip map<bool, bool>" {
    var msg = TestAllTypesProto3{};
    try msg.map_bool_bool.append(allocator, .{ .key = true, .value = false });
    defer msg.map_bool_bool.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_bool_bool.items.len == 1);
    try expect(decoded.value.map_bool_bool.items[0].key == true);
    try expect(decoded.value.map_bool_bool.items[0].value == false);
}

test "JSON map: roundtrip map<uint64, uint64>" {
    var msg = TestAllTypesProto3{};
    try msg.map_uint64_uint64.append(allocator, .{ .key = 18446744073709551615, .value = 1 });
    defer msg.map_uint64_uint64.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_uint64_uint64.items.len == 1);
    try expect(decoded.value.map_uint64_uint64.items[0].key == 18446744073709551615);
    try expect(decoded.value.map_uint64_uint64.items[0].value == 1);
}

test "JSON map: roundtrip map<string, NestedEnum>" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_enum.append(allocator, .{ .key = "baz", .value = .BAZ });
    defer msg.map_string_nested_enum.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_string_nested_enum.items.len == 1);
    try expectEqualSlices(u8, "baz", decoded.value.map_string_nested_enum.items[0].key);
    try expect(decoded.value.map_string_nested_enum.items[0].value == .BAZ);
}

// --- Additional key type coverage tests (sint, fixed, sfixed) ---

test "JSON map: roundtrip map<sint32, sint32> with positive and negative values" {
    var msg = TestAllTypesProto3{};
    try msg.map_sint32_sint32.append(allocator, .{ .key = -42, .value = 100 });
    try msg.map_sint32_sint32.append(allocator, .{ .key = 7, .value = -50 });
    defer msg.map_sint32_sint32.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_sint32_sint32.items.len == 2);
    try expect(decoded.value.map_sint32_sint32.items[0].key == -42);
    try expect(decoded.value.map_sint32_sint32.items[0].value == 100);
    try expect(decoded.value.map_sint32_sint32.items[1].key == 7);
    try expect(decoded.value.map_sint32_sint32.items[1].value == -50);
}

test "JSON map: roundtrip map<fixed32, fixed32> with large value" {
    var msg = TestAllTypesProto3{};
    try msg.map_fixed32_fixed32.append(allocator, .{ .key = 4294967295, .value = 1 });
    defer msg.map_fixed32_fixed32.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_fixed32_fixed32.items.len == 1);
    try expect(decoded.value.map_fixed32_fixed32.items[0].key == 4294967295);
    try expect(decoded.value.map_fixed32_fixed32.items[0].value == 1);
}

test "JSON map: roundtrip map<sfixed64, sfixed64> with negative value" {
    var msg = TestAllTypesProto3{};
    try msg.map_sfixed64_sfixed64.append(allocator, .{ .key = -9223372036854775808, .value = 42 });
    defer msg.map_sfixed64_sfixed64.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_sfixed64_sfixed64.items.len == 1);
    try expect(decoded.value.map_sfixed64_sfixed64.items[0].key == -9223372036854775808);
    try expect(decoded.value.map_sfixed64_sfixed64.items[0].value == 42);
}

// --- Decode test for enum map values with string name ---

test "JSON map: decode map<string, NestedEnum> with string enum name" {
    const json_str =
        \\{"mapStringNestedEnum":{"foo":"BAR"}}
    ;
    const result = try TestAllTypesProto3.jsonDecode(json_str, .{}, allocator);
    defer result.deinit();

    try expect(result.value.map_string_nested_enum.items.len == 1);
    try expectEqualSlices(u8, "foo", result.value.map_string_nested_enum.items[0].key);
    try expect(result.value.map_string_nested_enum.items[0].value == .BAR);
}

// --- Negative integer key tests ---

test "JSON map: roundtrip map<int32, int32> with negative key" {
    var msg = TestAllTypesProto3{};
    try msg.map_int32_int32.append(allocator, .{ .key = -2147483648, .value = 1 });
    try msg.map_int32_int32.append(allocator, .{ .key = -1, .value = 2 });
    defer msg.map_int32_int32.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Verify negative keys are stringified correctly via JSON parsing
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const map = root.get("mapInt32Int32").?;
    try expect(map == .object);
    try expect(map.object.get("-2147483648").?.integer == 1);
    try expect(map.object.get("-1").?.integer == 2);
    try expect(map.object.count() == 2);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_int32_int32.items.len == 2);
    try expect(decoded.value.map_int32_int32.items[0].key == -2147483648);
    try expect(decoded.value.map_int32_int32.items[0].value == 1);
    try expect(decoded.value.map_int32_int32.items[1].key == -1);
    try expect(decoded.value.map_int32_int32.items[1].value == 2);
}

test "JSON map: encode map<string, NestedMessage> with null value writes empty object" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_message.append(allocator, .{ .key = "empty", .value = null });
    defer msg.map_string_nested_message.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Parse and validate JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapStringNestedMessage").?;
    try expect(map == .object);
    const empty_val = map.object.get("empty").?;
    try expect(empty_val == .object);
    try expect(empty_val.object.count() == 0);
}

test "JSON map: roundtrip map<string, NestedMessage> with null value" {
    var msg = TestAllTypesProto3{};
    try msg.map_string_nested_message.append(allocator, .{ .key = "present", .value = .{ .a = 42 } });
    try msg.map_string_nested_message.append(allocator, .{ .key = "absent", .value = null });
    defer msg.map_string_nested_message.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Validate encoded JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const map = root.get("mapStringNestedMessage").?;
    try expect(map == .object);
    // "present" should be an object with a=42
    const present = map.object.get("present").?;
    try expect(present == .object);
    try expect(present.object.get("a").?.integer == 42);
    // "absent" should be an empty object
    const absent = map.object.get("absent").?;
    try expect(absent == .object);
    try expect(absent.object.count() == 0);

    const decoded = try TestAllTypesProto3.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.map_string_nested_message.items.len == 2);
    try expectEqualSlices(u8, "present", decoded.value.map_string_nested_message.items[0].key);
    try expect(decoded.value.map_string_nested_message.items[0].value.?.a == 42);
    try expectEqualSlices(u8, "absent", decoded.value.map_string_nested_message.items[1].key);
    try expect(decoded.value.map_string_nested_message.items[1].value != null);
    try expect(decoded.value.map_string_nested_message.items[1].value.?.a == 0);
}

// =============================================================================
// Well-Known Type JSON encoding/decoding tests
// =============================================================================
// Per the proto3 JSON mapping specification, well-known types have special
// JSON representations that differ from normal message encoding.

const google_protobuf = @import("./generated/google/protobuf.pb.zig");
const Timestamp = google_protobuf.Timestamp;
const Duration = google_protobuf.Duration;
const Value = google_protobuf.Value;
const Struct = google_protobuf.Struct;
const ListValue = google_protobuf.ListValue;
const FieldMask = google_protobuf.FieldMask;
const DoubleValue = google_protobuf.DoubleValue;
const FloatValue = google_protobuf.FloatValue;
const Int64Value = google_protobuf.Int64Value;
const UInt64Value = google_protobuf.UInt64Value;
const Int32Value = google_protobuf.Int32Value;
const UInt32Value = google_protobuf.UInt32Value;
const BoolValue = google_protobuf.BoolValue;
const StringValue = google_protobuf.StringValue;
const BytesValue = google_protobuf.BytesValue;

// --- Wrapper Types ---

test "WKT: encode/decode DoubleValue" {
    const msg = DoubleValue{ .value = 3.14 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    // Should be a bare JSON number, not wrapped in {"value": 3.14}
    try expect(std.mem.indexOf(u8, encoded, "value") == null);

    const decoded = try DoubleValue.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 3.14);
}

test "WKT: encode/decode Int32Value" {
    const msg = Int32Value{ .value = 42 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "42"));

    const decoded = try Int32Value.jsonDecode("42", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 42);
}

test "WKT: encode/decode Int64Value (quoted string)" {
    const msg = Int64Value{ .value = 9223372036854775807 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    // Proto JSON spec: 64-bit integers must be quoted strings
    try expect(compare_pb_jsons(encoded, "\"9223372036854775807\""));

    // Decode from string
    const decoded = try Int64Value.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 9223372036854775807);

    // Also accept bare number (for interop with non-compliant producers)
    const decoded2 = try Int64Value.jsonDecode("9223372036854775807", .{}, allocator);
    defer decoded2.deinit();
    try expect(decoded2.value.value == 9223372036854775807);
}

test "WKT: encode/decode Int64Value negative (quoted string)" {
    const msg = Int64Value{ .value = -9223372036854775808 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"-9223372036854775808\""));

    const decoded = try Int64Value.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == -9223372036854775808);
}

test "WKT: encode/decode UInt64Value (quoted string)" {
    const msg = UInt64Value{ .value = 18446744073709551615 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"18446744073709551615\""));

    const decoded = try UInt64Value.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 18446744073709551615);

    // Also accept bare number
    const decoded2 = try UInt64Value.jsonDecode("18446744073709551615", .{}, allocator);
    defer decoded2.deinit();
    try expect(decoded2.value.value == 18446744073709551615);
}

test "WKT: encode/decode FloatValue" {
    const msg = FloatValue{ .value = 2.5 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try FloatValue.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 2.5);
}

test "WKT: encode/decode FloatValue NaN" {
    const msg = FloatValue{ .value = std.math.nan(f32) };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"NaN\""));
}

test "WKT: encode/decode UInt32Value" {
    const msg = UInt32Value{ .value = 4294967295 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "4294967295"));

    const decoded = try UInt32Value.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == 4294967295);
}

test "WKT: encode/decode BoolValue" {
    const msg = BoolValue{ .value = true };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "true"));

    const decoded = try BoolValue.jsonDecode("true", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.value == true);
}

test "WKT: encode/decode StringValue" {
    const msg = StringValue{ .value = "hello" };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"hello\""));

    const decoded = try StringValue.jsonDecode("\"hello\"", .{}, allocator);
    defer decoded.deinit();
    try expectEqualSlices(u8, "hello", decoded.value.value);
}

test "WKT: encode/decode BytesValue" {
    const msg = BytesValue{ .value = "abc" };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    // base64("abc") = "YWJj"
    try expect(compare_pb_jsons(encoded, "\"YWJj\""));

    const decoded = try BytesValue.jsonDecode("\"YWJj\"", .{}, allocator);
    defer decoded.deinit();
    try expectEqualSlices(u8, "abc", decoded.value.value);
}

// --- Timestamp ---

test "WKT: encode Timestamp epoch zero" {
    const msg = Timestamp{ .seconds = 0, .nanos = 0 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"1970-01-01T00:00:00Z\""));
}

test "WKT: encode Timestamp with nanos (3 digits)" {
    const msg = Timestamp{ .seconds = 0, .nanos = 100_000_000 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"1970-01-01T00:00:00.100Z\""));
}

test "WKT: encode Timestamp with nanos (6 digits)" {
    const msg = Timestamp{ .seconds = 0, .nanos = 100_100_000 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"1970-01-01T00:00:00.100100Z\""));
}

test "WKT: encode Timestamp with nanos (9 digits)" {
    const msg = Timestamp{ .seconds = 0, .nanos = 100_100_100 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"1970-01-01T00:00:00.100100100Z\""));
}

test "WKT: encode Timestamp normal date" {
    // 2024-01-15T12:30:45Z
    const msg = Timestamp{ .seconds = 1705321845, .nanos = 0 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"2024-01-15T12:30:45Z\""));
}

test "WKT: roundtrip Timestamp" {
    const msg = Timestamp{ .seconds = 1705321845, .nanos = 123_456_789 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try Timestamp.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == 1705321845);
    try expect(decoded.value.nanos == 123_456_789);
}

test "WKT: decode Timestamp" {
    const decoded = try Timestamp.jsonDecode("\"2024-01-15T12:30:45.123Z\"", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == 1705321845);
    try expect(decoded.value.nanos == 123_000_000);
}

// --- Duration ---

test "WKT: encode Duration zero" {
    const msg = Duration{ .seconds = 0, .nanos = 0 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"0s\""));
}

test "WKT: encode Duration positive" {
    const msg = Duration{ .seconds = 123, .nanos = 0 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"123s\""));
}

test "WKT: encode Duration with nanos" {
    const msg = Duration{ .seconds = 3, .nanos = 1_000 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"3.000001s\""));
}

test "WKT: encode Duration negative" {
    const msg = Duration{ .seconds = -123, .nanos = -456_000_000 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"-123.456s\""));
}

test "WKT: roundtrip Duration" {
    const msg = Duration{ .seconds = 3, .nanos = 1_000 };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try Duration.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == 3);
    try expect(decoded.value.nanos == 1_000);
}

test "WKT: decode Duration negative" {
    const decoded = try Duration.jsonDecode("\"-5.500s\"", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == -5);
    try expect(decoded.value.nanos == -500_000_000);
}

// --- Value / Struct / ListValue ---

test "WKT: encode Value null" {
    const msg = Value{ .kind = .{ .null_value = .NULL_VALUE } };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "null"));
}

test "WKT: encode Value number" {
    const msg = Value{ .kind = .{ .number_value = 42.5 } };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    // Check that it parses as the correct number (format may vary)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try expect(parsed.value == .float);
    try expect(parsed.value.float == 42.5);
}

test "WKT: encode Value string" {
    const msg = Value{ .kind = .{ .string_value = "hello" } };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"hello\""));
}

test "WKT: encode Value bool" {
    const msg = Value{ .kind = .{ .bool_value = true } };
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "true"));
}

test "WKT: encode Struct" {
    var s = Struct{};
    try s.fields.append(allocator, .{
        .key = "name",
        .value = Value{ .kind = .{ .string_value = "test" } },
    });
    defer s.fields.deinit(allocator);

    const encoded = try s.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Should be {"name":"test"} not {"fields":[{"key":"name","value":"test"}]}
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try expect(parsed.value == .object);
    const name_val = parsed.value.object.get("name").?;
    try expect(name_val == .string);
    try expectEqualSlices(u8, "test", name_val.string);
}

test "WKT: encode ListValue" {
    var lv = ListValue{};
    try lv.values.append(allocator, Value{ .kind = .{ .number_value = 1.0 } });
    try lv.values.append(allocator, Value{ .kind = .{ .string_value = "two" } });
    try lv.values.append(allocator, Value{ .kind = .{ .bool_value = false } });
    defer lv.values.deinit(allocator);

    const encoded = try lv.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    // Should be [1.0,"two",false] not {"values":[...]}
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try expect(parsed.value == .array);
    try expect(parsed.value.array.items.len == 3);
}

test "WKT: decode Value number" {
    const decoded = try Value.jsonDecode("42.5", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.kind.?.number_value == 42.5);
}

test "WKT: decode Value string" {
    const decoded = try Value.jsonDecode("\"hello\"", .{}, allocator);
    defer decoded.deinit();
    try expectEqualSlices(u8, "hello", decoded.value.kind.?.string_value);
}

test "WKT: decode Value bool" {
    const decoded = try Value.jsonDecode("true", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.kind.?.bool_value == true);
}

test "WKT: decode Value null" {
    const decoded = try Value.jsonDecode("null", .{}, allocator);
    defer decoded.deinit();
    try expect(@as(google_protobuf.NullValue, decoded.value.kind.?.null_value) == .NULL_VALUE);
}

test "WKT: decode Struct" {
    const decoded = try Struct.jsonDecode("{\"a\":1,\"b\":\"two\"}", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.fields.items.len == 2);
    try expectEqualSlices(u8, "a", decoded.value.fields.items[0].key);
    try expect(decoded.value.fields.items[0].value.?.kind.?.number_value == 1.0);
    try expectEqualSlices(u8, "b", decoded.value.fields.items[1].key);
    try expectEqualSlices(u8, "two", decoded.value.fields.items[1].value.?.kind.?.string_value);
}

test "WKT: decode ListValue" {
    const decoded = try ListValue.jsonDecode("[1,\"two\",true]", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.values.items.len == 3);
    try expect(decoded.value.values.items[0].kind.?.number_value == 1.0);
    try expectEqualSlices(u8, "two", decoded.value.values.items[1].kind.?.string_value);
    try expect(decoded.value.values.items[2].kind.?.bool_value == true);
}

test "WKT: roundtrip nested Value/Struct/ListValue" {
    // {"data": [1, {"nested": true}]}
    var inner_struct = Struct{};
    try inner_struct.fields.append(allocator, .{
        .key = "nested",
        .value = Value{ .kind = .{ .bool_value = true } },
    });

    var list = ListValue{};
    try list.values.append(allocator, Value{ .kind = .{ .number_value = 1.0 } });
    try list.values.append(allocator, Value{ .kind = .{ .struct_value = inner_struct } });

    var s = Struct{};
    try s.fields.append(allocator, .{
        .key = "data",
        .value = Value{ .kind = .{ .list_value = list } },
    });
    // Must clean up all levels: s.fields owns the list and inner_struct transitively
    defer {
        // Inner struct's fields ArrayList
        inner_struct.fields.deinit(allocator);
        // ListValue's values ArrayList
        list.values.deinit(allocator);
        // Outer struct's fields ArrayList
        s.fields.deinit(allocator);
    }

    const encoded = try s.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try Struct.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();

    try expect(decoded.value.fields.items.len == 1);
    try expectEqualSlices(u8, "data", decoded.value.fields.items[0].key);
    const list_val = decoded.value.fields.items[0].value.?.kind.?.list_value;
    try expect(list_val.values.items.len == 2);
    try expect(list_val.values.items[0].kind.?.number_value == 1.0);
    try expect(list_val.values.items[1].kind.?.struct_value.fields.items[0].value.?.kind.?.bool_value == true);
}

// --- FieldMask ---

test "WKT: encode FieldMask empty" {
    const msg = FieldMask{};
    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"\""));
}

test "WKT: encode FieldMask single path" {
    var msg = FieldMask{};
    try msg.paths.append(allocator, "foo_bar");
    defer msg.paths.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"fooBar\""));
}

test "WKT: encode FieldMask multiple paths" {
    var msg = FieldMask{};
    try msg.paths.append(allocator, "foo_bar");
    try msg.paths.append(allocator, "baz_qux");
    defer msg.paths.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);
    try expect(compare_pb_jsons(encoded, "\"fooBar,bazQux\""));
}

test "WKT: decode FieldMask" {
    const decoded = try FieldMask.jsonDecode("\"fooBar,bazQux\"", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.paths.items.len == 2);
    try expectEqualSlices(u8, "foo_bar", decoded.value.paths.items[0]);
    try expectEqualSlices(u8, "baz_qux", decoded.value.paths.items[1]);
}

test "WKT: roundtrip FieldMask" {
    var msg = FieldMask{};
    try msg.paths.append(allocator, "foo_bar");
    try msg.paths.append(allocator, "baz_qux_nested");
    defer msg.paths.deinit(allocator);

    const encoded = try msg.jsonEncode(.{}, .{}, allocator);
    defer allocator.free(encoded);

    const decoded = try FieldMask.jsonDecode(encoded, .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.paths.items.len == 2);
    try expectEqualSlices(u8, "foo_bar", decoded.value.paths.items[0]);
    try expectEqualSlices(u8, "baz_qux_nested", decoded.value.paths.items[1]);
}

// --- Range Validation Tests ---

test "WKT: Timestamp rejects seconds too large" {
    const ts = Timestamp{ .seconds = 253402300800, .nanos = 0 };
    try std.testing.expectError(error.RangeError, ts.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Timestamp rejects seconds too small" {
    const ts = Timestamp{ .seconds = -62135596801, .nanos = 0 };
    try std.testing.expectError(error.RangeError, ts.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Timestamp rejects negative nanos" {
    const ts = Timestamp{ .seconds = 0, .nanos = -1 };
    try std.testing.expectError(error.RangeError, ts.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Timestamp rejects nanos too large" {
    const ts = Timestamp{ .seconds = 0, .nanos = 1_000_000_000 };
    try std.testing.expectError(error.RangeError, ts.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Duration rejects seconds too large" {
    const d = Duration{ .seconds = 315576000001, .nanos = 0 };
    try std.testing.expectError(error.RangeError, d.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Duration rejects seconds too small" {
    const d = Duration{ .seconds = -315576000001, .nanos = 0 };
    try std.testing.expectError(error.RangeError, d.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Duration rejects nanos wrong sign (positive secs, negative nanos)" {
    const d = Duration{ .seconds = 1, .nanos = -1 };
    try std.testing.expectError(error.RangeError, d.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Duration rejects nanos wrong sign (negative secs, positive nanos)" {
    const d = Duration{ .seconds = -1, .nanos = 1 };
    try std.testing.expectError(error.RangeError, d.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Duration parse rejects too large" {
    const result = Duration.jsonDecode("\"315576000001s\"", .{}, allocator);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "WKT: Timestamp parse rejects date too small" {
    // 0000-12-31T23:59:59Z is before 0001-01-01T00:00:00Z
    const result = Timestamp.jsonDecode("\"0000-12-31T23:59:59Z\"", .{}, allocator);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "WKT: Timestamp parse with positive offset" {
    // 1970-01-01T08:00:00+08:00 is equivalent to 1970-01-01T00:00:00Z
    const decoded = try Timestamp.jsonDecode("\"1970-01-01T08:00:00+08:00\"", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == 0);
    try expect(decoded.value.nanos == 0);
}

test "WKT: Timestamp parse with negative offset" {
    // 1969-12-31T19:00:00-05:00 is equivalent to 1970-01-01T00:00:00Z
    const decoded = try Timestamp.jsonDecode("\"1969-12-31T19:00:00-05:00\"", .{}, allocator);
    defer decoded.deinit();
    try expect(decoded.value.seconds == 0);
    try expect(decoded.value.nanos == 0);
}

test "WKT: FieldMask rejects paths that don't round-trip (consecutive underscores)" {
    var msg = FieldMask{};
    try msg.paths.append(allocator, "foo__bar");
    defer msg.paths.deinit(allocator);
    try std.testing.expectError(error.RangeError, msg.jsonEncode(.{}, .{}, allocator));
}

test "WKT: FieldMask rejects paths that don't round-trip (trailing underscore)" {
    var msg = FieldMask{};
    try msg.paths.append(allocator, "foo_");
    defer msg.paths.deinit(allocator);
    try std.testing.expectError(error.RangeError, msg.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Value rejects NaN number_value" {
    const msg = Value{ .kind = .{ .number_value = std.math.nan(f64) } };
    try std.testing.expectError(error.RangeError, msg.jsonEncode(.{}, .{}, allocator));
}

test "WKT: Value rejects Infinity number_value" {
    const msg = Value{ .kind = .{ .number_value = std.math.inf(f64) } };
    try std.testing.expectError(error.RangeError, msg.jsonEncode(.{}, .{}, allocator));
}
