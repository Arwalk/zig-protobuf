const std = @import("std");
const testing = std.testing;
const opts = @import("./generated/tests/options.pb.zig");
const descriptor = @import("./generated/google/protobuf.pb.zig");

// Options are decoded at generation time into comptime constants: anonymous
// structs of the options that are set, where custom options are keyed by the
// full name of their extension.

test "options: file options, without source-retention options" {
    const file = @field(opts._file_options, "options.proto");
    try testing.expectEqualStrings("abc", file.@"tests.options.file_options".file_only_option);

    // protoc strips source-retention options before code generation.
    try testing.expect(!@hasField(@TypeOf(file), "tests.options.source_retention_option"));
}

test "options: message options of every kind" {
    const options = opts.MyMessage._options.@"tests.options.message_options";
    try testing.expectEqual(42, options.message_and_enum_option);
    try testing.expectEqual(.{ 1, 2 }, options.numbers);
    try testing.expectEqual(.MY_ENUM_DISPLAY, options.kind);
    try testing.expectEqual(0.5, options.ratio);
    try testing.expectEqualSlices(u8, "\x01\xff", options.blob);
    try testing.expectEqual(-3, options.delta);
    try testing.expectEqual(1, options.inner.x);
    try testing.expectEqual(2, options.inners[0].x);
    try testing.expectEqual(3, options.inners[1].x);

    // Options are comptime-known.
    comptime std.debug.assert(options.message_and_enum_option == 42);
}

test "options: field and oneof options" {
    const field = opts.MyMessage._field_options.old_field;
    try testing.expectEqual(true, field.deprecated);
    try testing.expectEqualStrings("old", field.@"tests.options.field_label");

    // Only the fields with options are listed.
    try testing.expect(!@hasField(@TypeOf(opts.MyMessage._field_options), "plain"));

    try testing.expectEqual(true, opts.MyMessage._oneof_options.choice.@"tests.options.oneof_flag");
}

test "options: enum and enum value options" {
    try testing.expectEqual(7, opts.MyEnum._options.@"tests.options.enum_options".message_and_enum_option);
    try testing.expectEqualStrings("display_value", opts.MyEnum._value_options.MY_ENUM_DISPLAY.@"tests.options.string_name");
    try testing.expectEqual(true, opts.MyEnum._value_options.MY_ENUM_OLD.deprecated);
}

test "options: service and method options" {
    const Service = opts.MyService(void, error{});
    try testing.expectEqualStrings("svc", Service._options.@"tests.options.service_label");
    try testing.expectEqual(30, Service._method_options.Call.@"tests.options.method_timeout");
}

test "options: options of extension fields" {
    // The definition of `source_retention_option` sets `retention`.
    try testing.expectEqual(.RETENTION_SOURCE, opts.source_retention_option.options.retention);
    try testing.expectEqual(0, @typeInfo(@TypeOf(opts.file_options.options)).@"struct".fields.len);
}

test "options: target types of an option field" {
    try testing.expectEqual(.{ .TARGET_TYPE_MESSAGE, .TARGET_TYPE_ENUM }, opts.MyOptions._field_options.message_and_enum_option.targets);
}

test "options: raw encoded options, for the usual decoding APIs" {
    // `#raw` holds the encoded `google.protobuf.*Options` message.
    const raw = opts.MyMessage._options.@"#raw";
    var custom = try opts.message_options.getFromBytes(raw, testing.allocator);
    defer opts.message_options.deinitValue(&custom, testing.allocator);
    try testing.expectEqual(42, custom.?.message_and_enum_option);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, custom.?.numbers.items);

    // Standard options decode with the descriptor bindings.
    var reader: std.Io.Reader = .fixed(opts.MyMessage._field_options.old_field.@"#raw");
    var field_options = try descriptor.FieldOptions.decode(&reader, testing.allocator);
    defer field_options.deinit(testing.allocator);
    try testing.expectEqual(true, field_options.deprecated.?);
}
