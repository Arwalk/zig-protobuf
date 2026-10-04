//! Port of the option tests of protobuf v36.2, on its test protos (see
//! tests/protos_for_test/upstream):
//!
//! * `CustomOptions` tests of src/google/protobuf/descriptor_unittest.cc,
//!   on unittest_custom_options.proto and the files of `ported/`.
//! * `RetentionTest` tests of src/google/protobuf/retention_test.cc, on
//!   unittest_retention.proto.
//!
//! Tests of protoc validation (unused imports, invalid descriptors, feature
//! support) and of the C++ API (`DebugString`) have no equivalent here.

const std = @import("std");
const testing = std.testing;
const pb = @import("./generated/upstream/proto2_unittest.pb.zig");
const import_option = @import("./generated/upstream/proto2_unittest_import_option.pb.zig");
const ported = @import("./generated/upstream/ported_options.pb.zig");
const ported2024 = @import("./generated/upstream/ported/options2024.pb.zig");

const custom_options_file = @field(pb._file_options, "google/protobuf/unittest_custom_options.proto");
const retention_file = @field(pb._file_options, "google/protobuf/unittest_retention.proto");

// ---------------------------------------------------------------------------
// descriptor_unittest.cc

test "CustomOptions.OptionLocations" {
    const message = pb.TestMessageWithCustomOptions;

    try testing.expectEqual(9876543210, custom_options_file.@"proto2_unittest.file_opt1");
    try testing.expectEqual(-56, message._options.@"proto2_unittest.message_opt1");
    try testing.expectEqual(8765432109, message._field_options.field1.@"proto2_unittest.field_opt1");
    // An option that is not set has the default value of its extension.
    try testing.expect(!@hasField(@TypeOf(message._field_options.field1), "proto2_unittest.field_opt2"));
    try testing.expectEqual(42, pb.field_opt2.default);
    try testing.expectEqual(-99, message._oneof_options.AnOneof.@"proto2_unittest.oneof_opt1");
    try testing.expectEqual(12345, message._field_options.map_field.@"proto2_unittest.field_opt1");
    try testing.expectEqual(-789, message.AnEnum._options.@"proto2_unittest.enum_opt1");
    try testing.expectEqual(123, message.AnEnum._value_options.ANENUM_VAL2.@"proto2_unittest.enum_value_opt1");

    const Service = pb.TestServiceWithCustomOptions(void, error{});
    try testing.expectEqual(-9876543210, Service._options.@"proto2_unittest.service_opt1");
    try testing.expectEqual(.METHODOPT1_VAL2, Service._method_options.Foo.@"proto2_unittest.method_opt1");

    // The regular options went through unscathed: `message_set_wire_format`
    // is set (to false). Options that are set are the fields of the constant.
    try testing.expect(@hasField(@TypeOf(message._options), "message_set_wire_format"));
    try testing.expectEqual(false, message._options.message_set_wire_format);
}

test "CustomOptions.OptionTypes" {
    const min = pb.CustomOptionMinIntegerValues._options;
    try testing.expectEqual(false, min.@"proto2_unittest.bool_opt");
    try testing.expectEqual(std.math.minInt(i32), min.@"proto2_unittest.int32_opt");
    try testing.expectEqual(std.math.minInt(i64), min.@"proto2_unittest.int64_opt");
    try testing.expectEqual(0, min.@"proto2_unittest.uint32_opt");
    try testing.expectEqual(0, min.@"proto2_unittest.uint64_opt");
    try testing.expectEqual(std.math.minInt(i32), min.@"proto2_unittest.sint32_opt");
    try testing.expectEqual(std.math.minInt(i64), min.@"proto2_unittest.sint64_opt");
    try testing.expectEqual(0, min.@"proto2_unittest.fixed32_opt");
    try testing.expectEqual(0, min.@"proto2_unittest.fixed64_opt");
    try testing.expectEqual(std.math.minInt(i32), min.@"proto2_unittest.sfixed32_opt");
    try testing.expectEqual(std.math.minInt(i64), min.@"proto2_unittest.sfixed64_opt");

    const max = pb.CustomOptionMaxIntegerValues._options;
    try testing.expectEqual(true, max.@"proto2_unittest.bool_opt");
    try testing.expectEqual(std.math.maxInt(i32), max.@"proto2_unittest.int32_opt");
    try testing.expectEqual(std.math.maxInt(i64), max.@"proto2_unittest.int64_opt");
    try testing.expectEqual(std.math.maxInt(u32), max.@"proto2_unittest.uint32_opt");
    try testing.expectEqual(std.math.maxInt(u64), max.@"proto2_unittest.uint64_opt");
    try testing.expectEqual(std.math.maxInt(i32), max.@"proto2_unittest.sint32_opt");
    try testing.expectEqual(std.math.maxInt(i64), max.@"proto2_unittest.sint64_opt");
    try testing.expectEqual(std.math.maxInt(u32), max.@"proto2_unittest.fixed32_opt");
    try testing.expectEqual(std.math.maxInt(u64), max.@"proto2_unittest.fixed64_opt");
    try testing.expectEqual(std.math.maxInt(i32), max.@"proto2_unittest.sfixed32_opt");
    try testing.expectEqual(std.math.maxInt(i64), max.@"proto2_unittest.sfixed64_opt");

    const other = pb.CustomOptionOtherValues._options;
    try testing.expectEqual(-100, other.@"proto2_unittest.int32_opt");
    try testing.expectApproxEqRel(@as(f32, 12.3456789), @as(f32, other.@"proto2_unittest.float_opt"), 1e-6);
    try testing.expectApproxEqRel(@as(f64, 1.234567890123456789), @as(f64, other.@"proto2_unittest.double_opt"), 1e-15);
    try testing.expectEqualStrings("Hello, \"World\"", other.@"proto2_unittest.string_opt");
    try testing.expectEqualSlices(u8, "Hello\x00World", other.@"proto2_unittest.bytes_opt");
    try testing.expectEqual(.TEST_OPTION_ENUM_TYPE2, other.@"proto2_unittest.enum_opt");

    try testing.expectEqual(12, pb.SettingRealsFromPositiveInts._options.@"proto2_unittest.float_opt");
    try testing.expectEqual(154, pb.SettingRealsFromPositiveInts._options.@"proto2_unittest.double_opt");
    try testing.expectEqual(-12, pb.SettingRealsFromNegativeInts._options.@"proto2_unittest.float_opt");
    try testing.expectEqual(-154, pb.SettingRealsFromNegativeInts._options.@"proto2_unittest.double_opt");

    // Decoding `#raw` gives the same values.
    try testing.expectEqual(std.math.minInt(i64), (try pb.sint64_opt.getFromBytes(min.@"#raw", testing.allocator)).?);
    try testing.expectEqual(std.math.maxInt(u64), (try pb.fixed64_opt.getFromBytes(max.@"#raw", testing.allocator)).?);
    try testing.expectEqual(@as(f32, other.@"proto2_unittest.float_opt"), (try pb.float_opt.getFromBytes(other.@"#raw", testing.allocator)).?);
    try testing.expectEqual(@as(f64, other.@"proto2_unittest.double_opt"), (try pb.double_opt.getFromBytes(other.@"#raw", testing.allocator)).?);
    var bytes = try pb.bytes_opt.getFromBytes(other.@"#raw", testing.allocator);
    defer pb.bytes_opt.deinitValue(&bytes, testing.allocator);
    try testing.expectEqualSlices(u8, "Hello\x00World", bytes.?);
}

test "CustomOptions.ComplexExtensionOptions" {
    const options = pb.VariousComplexOptions._options;

    const opt1 = options.@"proto2_unittest.complex_opt1";
    try testing.expectEqual(42, opt1.foo);
    try testing.expectEqual(324, opt1.@"proto2_unittest.mooo");
    try testing.expectEqual(876, opt1.@"proto2_unittest.corge".moo);

    const opt2 = options.@"proto2_unittest.complex_opt2";
    try testing.expectEqual(987, opt2.baz);
    try testing.expectEqual(654, opt2.@"proto2_unittest.grault");
    try testing.expectEqual(743, opt2.bar.foo);
    try testing.expectEqual(1999, opt2.bar.@"proto2_unittest.mooo");
    try testing.expectEqual(2008, opt2.bar.@"proto2_unittest.corge".moo);
    try testing.expectEqual(741, opt2.@"proto2_unittest.garply".foo);
    try testing.expectEqual(1998, opt2.@"proto2_unittest.garply".@"proto2_unittest.mooo");
    try testing.expectEqual(2121, opt2.@"proto2_unittest.garply".@"proto2_unittest.corge".moo);
    try testing.expectEqual(1971, options.@"proto2_unittest.ComplexOptionType2.ComplexOptionType4.complex_opt4".waldo);
    try testing.expectEqual(321, opt2.fred.waldo);

    try testing.expectEqual(9, options.@"proto2_unittest.complex_opt3".moo);
    try testing.expectEqual(22, options.@"proto2_unittest.complex_opt3".complexoptiontype5.plugh);
    try testing.expectEqual(24, options.@"proto2_unittest.complexopt6".xyzzy);
}

test "CustomOptions.OptionsFromDependency" {
    const file = @field(ported._file_options, "ported/custom_options_import.proto");
    try testing.expectEqual(1234, file.@"proto2_unittest.file_opt1");
    try testing.expectEqualStrings("foo", file.java_package);
    try testing.expectEqual(.SPEED, file.optimize_for);
}

test "CustomOptions.OptionsFromOptionDependency" {
    const file = @field(ported2024._file_options, "ported/custom_options_option_import.proto");
    try testing.expectEqual(1234, file.@"proto2_unittest.file_opt1");

    // unittest_import_option.proto sets options of two option dependencies.
    const imported = @field(import_option._file_options, "google/protobuf/unittest_import_option.proto");
    try testing.expectEqual(1, imported.@"proto2_unittest.file_opt1");
    try testing.expectEqual(1, imported.@"proto2_unittest_unlinked.file_opt1");
    try testing.expectEqual(2, import_option.TestMessage._options.@"proto2_unittest.message_opt1");
    try testing.expectEqual(3, import_option.TestMessage._field_options.field1.@"proto2_unittest.field_opt1");
    try testing.expectEqual(3, import_option.TestMessage._field_options.field1.@"proto2_unittest_unlinked.field_opt1");
}

test "CustomOptions.OptionExtensionFromOptionDependency" {
    const options = ported2024.ExtensionFromOptionDependency._options;
    try testing.expectEqual(1234, options.@"proto2_unittest.complex_opt1".@"proto2_unittest.mooo");
}

test "CustomOptions.MessageOptionThreeFieldsSet" {
    const options = ported2024.ThreeFieldsSet._options.@"proto2_unittest.complex_opt1";
    try testing.expectEqual(1234, options.foo);
    try testing.expectEqual(1234, options.foo2);
    try testing.expectEqual(1234, options.foo3);
}

test "CustomOptions.MessageOptionRepeatedLeafFieldSet" {
    const options = ported2024.RepeatedLeafFieldSet._options.@"proto2_unittest.complex_opt1";
    try testing.expectEqual(3, options.foo4.len);
    try testing.expectEqual(.{ 12, 34, 56 }, options.foo4);
}

test "CustomOptions.MessageOptionRepeatedMsgFieldSet" {
    const options = ported2024.RepeatedMsgFieldSet._options.@"proto2_unittest.complex_opt2";
    try testing.expectEqual(3, options.barney.len);
    try testing.expectEqual(1, options.barney[0].waldo);
    try testing.expectEqual(10, options.barney[1].waldo);
    try testing.expectEqual(100, options.barney[2].waldo);
}

test "CustomOptions.AggregateOptions" {
    const file = custom_options_file.@"proto2_unittest.fileopt";
    try testing.expectEqual(100, file.i);
    try testing.expectEqualStrings("FileAnnotation", file.s);
    try testing.expectEqualStrings("NestedFileAnnotation", file.sub.s);
    try testing.expectEqualStrings("FileExtensionAnnotation", file.file.@"proto2_unittest.fileopt".s);
    // `mset` is a MessageSet: its items decode as extensions.
    try testing.expectEqualStrings(
        "EmbeddedMessageSetElement",
        file.mset.@"proto2_unittest.AggregateMessageSetElement.message_set_extension".s,
    );

    // `any` is a google.protobuf.Any, which holds an encoded message.
    try testing.expectEqualStrings("type.googleapis.com/proto2_unittest.AggregateMessageSetElement", file.any.type_url);
    var reader: std.Io.Reader = .fixed(file.any.value);
    var payload = try pb.AggregateMessageSetElement.decode(&reader, testing.allocator);
    defer payload.deinit(testing.allocator);
    try testing.expectEqualStrings("EmbeddedMessageSetElement", payload.s.?);

    try testing.expectEqualStrings("MessageAnnotation", pb.AggregateMessage._options.@"proto2_unittest.msgopt".s);
    try testing.expectEqualStrings("FieldAnnotation", pb.AggregateMessage._field_options.fieldname.@"proto2_unittest.fieldopt".s);
    try testing.expectEqualStrings("EnumAnnotation", pb.AggregateEnum._options.@"proto2_unittest.enumopt".s);
    try testing.expectEqualStrings("EnumValueAnnotation", pb.AggregateEnum._value_options.VALUE.@"proto2_unittest.enumvalopt".s);
    const Service = pb.AggregateService(void, error{});
    try testing.expectEqualStrings("ServiceAnnotation", Service._options.@"proto2_unittest.serviceopt".s);
    try testing.expectEqualStrings("MethodAnnotation", Service._method_options.Method.@"proto2_unittest.methodopt".s);
}

// ---------------------------------------------------------------------------
// retention_test.cc

/// `CheckOptionsMessageIsStrippedCorrectly`: the source-retention field of an
/// `OptionsMessage` is stripped, the other fields are kept.
fn expectStripped(options: anytype) !void {
    try testing.expectEqual(1, options.plain_field);
    try testing.expectEqual(2, options.runtime_retention_field);
    try testing.expect(!@hasField(@TypeOf(options), "source_retention_field"));
}

test "RetentionTest.DirectOptions" {
    try testing.expectEqual(1, retention_file.@"proto2_unittest.plain_option");
    try testing.expectEqual(2, retention_file.@"proto2_unittest.runtime_retention_option");
    // RETENTION_SOURCE option should be stripped.
    try testing.expect(!@hasField(@TypeOf(retention_file), "proto2_unittest.source_retention_option"));
}

test "RetentionTest.FieldsNestedInRepeatedMessage" {
    const repeated = retention_file.@"proto2_unittest.repeated_options";
    try testing.expectEqual(1, repeated.len);
    try expectStripped(repeated[0]);
}

test "RetentionTest.File" {
    try expectStripped(retention_file.@"proto2_unittest.file_option");
}

test "RetentionTest.TopLevelMessage" {
    try expectStripped(pb.TopLevelMessage._options.@"proto2_unittest.message_option");
}

test "RetentionTest.NestedMessage" {
    try expectStripped(pb.TopLevelMessage.NestedMessage._options.@"proto2_unittest.message_option");
}

test "RetentionTest.TopLevelEnum" {
    try expectStripped(pb.TopLevelEnum._options.@"proto2_unittest.enum_option");
}

test "RetentionTest.NestedEnum" {
    try expectStripped(pb.TopLevelMessage.NestedEnum._options.@"proto2_unittest.enum_option");
}

test "RetentionTest.EnumEntry" {
    try expectStripped(pb.TopLevelEnum._value_options.TOP_LEVEL_UNKNOWN.@"proto2_unittest.enum_entry_option");
}

test "RetentionTest.TopLevelExtension" {
    try expectStripped(pb.i.options.@"proto2_unittest.field_option");
}

test "RetentionTest.NestedExtension" {
    try expectStripped(pb.TopLevelMessage.s.options.@"proto2_unittest.field_option");
}

test "RetentionTest.Field" {
    try expectStripped(pb.TopLevelMessage._field_options.f.@"proto2_unittest.field_option");
}

test "RetentionTest.Oneof" {
    try expectStripped(pb.TopLevelMessage._oneof_options.o.@"proto2_unittest.oneof_option");
}

test "RetentionTest.ExtensionRange" {
    try expectStripped(pb.TopLevelMessage._extensions_info.range_options[0].@"proto2_unittest.extension_range_option");
}

test "RetentionTest.Service" {
    try expectStripped(pb.Service(void, error{})._options.@"proto2_unittest.service_option");
}

test "RetentionTest.Method" {
    try expectStripped(pb.Service(void, error{})._method_options.DoStuff.@"proto2_unittest.method_option");
}
