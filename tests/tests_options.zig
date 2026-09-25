const std = @import("std");
const testing = std.testing;
const opts = @import("./generated/tests/options.pb.zig");
const descriptor = @import("./generated/google/protobuf.pb.zig");

/// Decodes a standard options message from emitted option bytes.
fn decodeOptions(comptime T: type, encoded: []const u8) !T {
    var reader: std.Io.Reader = .fixed(encoded);
    return T.decode(&reader, testing.allocator);
}

test "options: file options, without source-retention options" {
    const encoded = @field(opts._file_options, "options.proto");

    var file_options = try opts.file_options.getFromBytes(encoded, testing.allocator);
    defer opts.file_options.deinitValue(&file_options, testing.allocator);
    try testing.expectEqualStrings("abc", file_options.?.file_only_option);

    // protoc strips source-retention options before code generation.
    try testing.expectEqual(null, try opts.source_retention_option.getFromBytes(encoded, testing.allocator));
}

test "options: message, field and oneof options" {
    var message_options = try opts.message_options.getFromBytes(opts.MyMessage._options, testing.allocator);
    defer opts.message_options.deinitValue(&message_options, testing.allocator);
    try testing.expectEqual(42, message_options.?.message_and_enum_option);

    // Custom and standard options of a field.
    const field = opts.MyMessage._field_options.old_field;
    var label = try opts.field_label.getFromBytes(field, testing.allocator);
    defer opts.field_label.deinitValue(&label, testing.allocator);
    try testing.expectEqualStrings("old", label.?);
    var field_options = try decodeOptions(descriptor.FieldOptions, field);
    defer field_options.deinit(testing.allocator);
    try testing.expectEqual(true, field_options.deprecated.?);

    // Only the fields with options are listed.
    try testing.expect(!@hasField(@TypeOf(opts.MyMessage._field_options), "plain"));

    try testing.expectEqual(true, (try opts.oneof_flag.getFromBytes(opts.MyMessage._oneof_options.choice, testing.allocator)).?);
}

test "options: enum and enum value options" {
    var enum_options = try opts.enum_options.getFromBytes(opts.MyEnum._options, testing.allocator);
    defer opts.enum_options.deinitValue(&enum_options, testing.allocator);
    try testing.expectEqual(7, enum_options.?.message_and_enum_option);

    var name = try opts.string_name.getFromBytes(opts.MyEnum._value_options.MY_ENUM_DISPLAY, testing.allocator);
    defer opts.string_name.deinitValue(&name, testing.allocator);
    try testing.expectEqualStrings("display_value", name.?);

    var value_options = try decodeOptions(descriptor.EnumValueOptions, opts.MyEnum._value_options.MY_ENUM_OLD);
    defer value_options.deinit(testing.allocator);
    try testing.expectEqual(true, value_options.deprecated.?);
}

test "options: service and method options" {
    const Service = opts.MyService(void, error{});

    var label = try opts.service_label.getFromBytes(Service._options, testing.allocator);
    defer opts.service_label.deinitValue(&label, testing.allocator);
    try testing.expectEqualStrings("svc", label.?);

    try testing.expectEqual(30, (try opts.method_timeout.getFromBytes(Service._method_options.Call, testing.allocator)).?);
}

test "options: options of extension fields" {
    // The definition of `source_retention_option` sets `retention`.
    var field_options = try decodeOptions(descriptor.FieldOptions, opts.source_retention_option.options);
    defer field_options.deinit(testing.allocator);
    try testing.expectEqual(.RETENTION_SOURCE, field_options.retention.?);
    try testing.expectEqual(0, opts.file_options.options.len);
}
