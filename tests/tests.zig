const std = @import("std");
const protobuf = @import("protobuf");
const mem = std.mem;
const Allocator = mem.Allocator;
const eql = mem.eql;
const fd = protobuf.fd;
const pb_decode = protobuf.pb_decode;
const pb_encode = protobuf.pb_encode;
const pb_deinit = protobuf.pb_deinit;
const pb_init = protobuf.pb_init;
const testing = std.testing;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const FieldType = protobuf.FieldType;
const tests = @import("./generated/tests.pb.zig");
const DefaultValues = @import("./generated/jspb/test.pb.zig").DefaultValues;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const assert = std.debug.assert;
const unittests = @import("./generated/unittest.pb.zig");
const TestService = unittests.TestService;
const FooRequest = unittests.FooRequest;
const FooResponse = unittests.FooResponse;
const BarRequest = unittests.BarRequest;
const BarResponse = unittests.BarResponse;

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "DefaultValuesInit" {
    var demo = DefaultValues.init(testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}

test "DefaultValuesDecode" {
    var demo = try DefaultValues.decode("", testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}

const TestServiceImplementation = struct {
    counter: u32,

    pub fn Foo(self: *TestServiceImplementation, _: FooRequest) FooResponse {
        self.counter += 1;
        return FooResponse{};
    }

    pub fn Bar(self:*TestServiceImplementation, _: BarRequest) BarResponse {
        self.counter += 1;
        return BarResponse{};
    }
};

test "services" {
    var testServiceImpl = TestServiceImplementation{.counter =  0};
    var testService = TestService.init(&testServiceImpl);

    _ = testService.Foo(FooRequest{});
    _ = testService.Bar(BarRequest{});

    try testing.expectEqual(2, testServiceImpl.counter);
}
