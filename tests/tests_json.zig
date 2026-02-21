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

test "JSON: encode Value (.number_value=NaN)" {
    const pb_instance = value_inits.get1();

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, value_camel_case1_json));
}

test "JSON: encode Value (.number_value=-Infinity)" {
    const pb_instance = value_inits.get2();

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, value_camel_case2_json));
}

test "JSON: encode Value (.number_value=Infinity)" {
    const pb_instance = value_inits.get3();

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        allocator,
    );
    defer allocator.free(encoded);

    try expect(compare_pb_jsons(encoded, value_camel_case3_json));
}

test "JSON: encode Value (.number_value=1.0)" {
    const pb_instance = value_inits.get4();

    const encoded = try pb_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
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
    // Use a wrapper so std.json.Stringify.valueAlloc calls our stringifyTo
    const Wrapper = struct {
        ptr: *const OneofContainer,
        pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
            return protobuf.json.stringifyWithOptions(
                OneofContainer,
                self.ptr,
                jws,
                .{ .emit_oneof_field_name = false },
            );
        }
    };
    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        Wrapper{ .ptr = &msg },
        .{},
    );
    defer allocator.free(encoded);
    // Flat format: no "someOneof" wrapper key; variant key directly in parent object
    try expect(std.mem.indexOf(u8, encoded, "someOneof") == null);
    try expect(std.mem.indexOf(u8, encoded, "stringInOneof") != null);
    try expect(std.mem.indexOf(u8, encoded, "regularField") != null);
}

test "JSON: encode oneof legacy wrapped format (emit_oneof_field_name=true)" {
    var pb_instance = try string_in_oneof_init(allocator);
    defer pb_instance.deinit(allocator);
    // Default jsonEncode uses wrapped format (backward compat)
    const encoded = try pb_instance.jsonEncode(.{}, allocator);
    defer allocator.free(encoded);
    // Legacy format: "someOneof" wrapper key present
    try expect(std.mem.indexOf(u8, encoded, "someOneof") != null);
    try expect(std.mem.indexOf(u8, encoded, "stringInOneof") != null);
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
    const Wrapper = struct {
        ptr: *const OneofContainer,
        pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
            return protobuf.json.stringifyWithOptions(
                OneofContainer,
                self.ptr,
                jws,
                .{ .emit_oneof_field_name = false },
            );
        }
    };
    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        Wrapper{ .ptr = &original },
        .{},
    );
    defer allocator.free(encoded);

    // Encoded JSON should not contain "someOneof" wrapper
    try expect(std.mem.indexOf(u8, encoded, "someOneof") == null);

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
