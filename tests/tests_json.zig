const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const ally = std.testing.allocator;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;

// TODO(libro): Also need to check if JSON string snake_case field
//   names will be decoded correctly (parser should handle
//   both camelCase and snake_case variants)

fn _compare_pb_strings(value1: ManagedString, value2: @TypeOf(value1)) bool {
    return std.mem.eql(u8, value1.getSlice(), value2.getSlice());
}

fn _compare_numerics(value1: anytype, value2: @TypeOf(value1)) bool {
    switch (@typeInfo(@TypeOf(value1))) {
        .Int, .ComptimeInt, .Enum, .Bool => {
            return value1 == value2;
        },
        .Float, .ComptimeFloat => {
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
            .Optional => |optional| optional.child,
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
            .Optional => {
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
            .List, .PackedList => |list_type| {
                if (field1.items.len != field2.items.len) return false;
                for (field1.items, field2.items) |array1_el, array2_el| {
                    if (!switch (list_type) {
                        .String => _compare_pb_strings(array1_el, array2_el),
                        .SubMessage => compare_pb_structs(array1_el, array2_el),
                        .Varint, .FixedInt => _compare_numerics(array1_el, array2_el),
                        else => std.meta.eql(array1_el, array2_el),
                    }) return false;
                }
            },
            .OneOf => {
                const union_info = switch (@typeInfo(@TypeOf(field1))) {
                    .Union => |u| u,
                    else => @compileError("Oneof should have .Union type"),
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
                            @TypeOf(field1)._union_desc,
                            field_info.name,
                        ).ftype) {
                            .String => _compare_pb_strings(
                                @field(field1, field_info.name),
                                @field(field2, field_info.name),
                            ),
                            .SubMessage => compare_pb_structs(
                                @field(field1, field_info.name),
                                @field(field2, field_info.name),
                            ),
                            else => std.meta.eql(
                                @field(field1, field_info.name),
                                @field(field2, field_info.name),
                            ),
                        }) return false;
                    }
                }
            },
            .String, .Bytes => {
                if (!_compare_pb_strings(field1, field2)) return false;
            },
            .SubMessage => {
                if (!compare_pb_structs(field1, field2)) return false;
            },
            .Varint, .FixedInt => {
                if (!_compare_numerics(field1, field2)) return false;
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

test "JSON: encode FixedSizes" {
    const pb_instance = fixed_sizes_init();
    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, fixed_sizes_camel_case_json));
}

test "JSON: decode FixedSizes (camelCase)" {
    const pb_instance = fixed_sizes_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        fixed_sizes_camel_case_json,
        .{},
        ally,
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
    const pb_instance = try repeated_enum_init(ally);
    defer pb_instance.deinit();

    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, repeated_enum_camel_case1_json));
}

test "JSON: decode RepeatedEnum (camelCase, variant 1)" {
    const pb_instance = try repeated_enum_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        repeated_enum_camel_case1_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode RepeatedEnum (camelCase, variant 2)" {
    const pb_instance = try repeated_enum_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        repeated_enum_camel_case2_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode RepeatedEnum (camelCase, variant 3)" {
    const pb_instance = try repeated_enum_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        repeated_enum_camel_case3_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// WithStrings tests
const with_strings_init = @import("./json_data/with_strings/instance.zig").get;
const with_strings_camel_case_json = @embedFile("./json_data/with_strings/camelCase.json");

test "JSON: encode WithStrings" {
    const pb_instance = with_strings_init();

    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, with_strings_camel_case_json));
}

test "JSON: decode WithStrings" {
    const pb_instance = with_strings_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        with_strings_camel_case_json,
        .{},
        ally,
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
    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, with_submessages_camel_case_json));
}

test "JSON: decode WithSubmessages (from camelCase)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        with_submessages_camel_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode WithSubmessages (from camelCase, enum as integer)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        with_submessages_camel_case_enum_as_integer_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode WithSubmessages (from snake_case)" {
    const pb_instance = with_submessages_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        with_submessages_snake_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// -----------
// Packed test
// -----------
const packed_init = @import("./json_data/packed/instance.zig").get;
const packed_camel_case_json = @embedFile("./json_data/packed/camelCase.json");
const packed_snake_case_json = @embedFile("./json_data/packed/snake_case.json");
const packed_mixed_case_json = @embedFile("./json_data/packed/mixed_case.json");

test "JSON: encode Packed" {
    const pb_instance = try packed_init(ally);
    defer pb_instance.deinit();

    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, packed_camel_case_json));
}

test "JSON: decode Packed (from camelCase)" {
    const pb_instance = try packed_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        packed_camel_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Packed (from snake_case)" {
    const pb_instance = try packed_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        packed_snake_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Packed (from mixed_case)" {
    const pb_instance = try packed_init(ally);
    defer pb_instance.deinit();

    const decoded = try @TypeOf(pb_instance).json_decode(
        packed_mixed_case_json,
        .{},
        ally,
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
    const pb_instance = string_in_oneof_init();
    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, string_in_oneof_camel_case_json));
}

test "JSON: decode OneofContainer (string_in_oneof) (from camelCase)" {
    const pb_instance = string_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        string_in_oneof_camel_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from snake_case)" {
    const pb_instance = string_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        string_in_oneof_snake_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from mixed_case1)" {
    const pb_instance = string_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        string_in_oneof_mixed_case1_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (string_in_oneof) (from mixed_case2)" {
    const pb_instance = string_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        string_in_oneof_mixed_case2_json,
        .{},
        ally,
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
    const pb_instance = message_in_oneof_init();
    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, message_in_oneof_camel_case_json));
}

test "JSON: decode OneofContainer (message_in_oneof) (from camelCase)" {
    const pb_instance = message_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        message_in_oneof_camel_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from snake_case)" {
    const pb_instance = message_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        message_in_oneof_snake_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from mixed_case1)" {
    const pb_instance = message_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        message_in_oneof_mixed_case1_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode OneofContainer (message_in_oneof) (from mixed_case2)" {
    const pb_instance = message_in_oneof_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        message_in_oneof_mixed_case2_json,
        .{},
        ally,
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
    const pb_instance = bytes_init();
    const encoded = try pb_instance.json_encode(
        .{ .whitespace = .indent_2 },
        ally,
    );
    defer ally.free(encoded);

    try expect(compare_pb_jsons(encoded, bytes_camel_case_json));
}

test "JSON: decode Bytes (from camelCase)" {
    const pb_instance = bytes_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        bytes_camel_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

test "JSON: decode Bytes (from snake_case)" {
    const pb_instance = bytes_init();

    const decoded = try @TypeOf(pb_instance).json_decode(
        bytes_snake_case_json,
        .{},
        ally,
    );
    defer decoded.deinit();

    try expect(compare_pb_structs(pb_instance, decoded.value));
}

// TODO: Test "repeated bytes" (MoreBytes instance for example)
// TODO: Test when oneof value == Nan/Infinity/-Infinity
