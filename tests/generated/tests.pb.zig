// Code generated by protoc-gen-zig
///! package tests
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;
const ManagedStruct = protobuf.ManagedStruct;
/// import package tests.oneof
const tests_oneof = @import("tests/oneof.pb.zig");
/// import package graphics
const graphics = @import("graphics.pb.zig");
/// import package tests.longs
const tests_longs = @import("tests/longs.pb.zig");
/// import package opentelemetry.proto.metrics.v1
const opentelemetry_proto_metrics_v1 = @import("opentelemetry/proto/metrics/v1.pb.zig");
/// import package opentelemetry.proto.logs.v1
const opentelemetry_proto_logs_v1 = @import("opentelemetry/proto/logs/v1.pb.zig");
/// import package protobuf_test_messages.proto3
pub const protobuf_test_messages_proto3 = @import("protobuf_test_messages/proto3.pb.zig");
/// import package unittest
pub const unittest = @import("unittest.pb.zig");
/// import package selfref
const selfref = @import("selfref.pb.zig");
/// import package oneofselfref
const oneofselfref = @import("oneofselfref.pb.zig");
/// import package jspb.test
pub const jspb_test = @import("jspb/test.pb.zig");
/// import package vector_tile
pub const vector_tile = @import("vector_tile.pb.zig");

pub const FixedSizes = struct {
    sfixed64: i64 = 0,
    sfixed32: i32 = 0,
    fixed32: u32 = 0,
    fixed64: u64 = 0,
    double: f64 = 0,
    float: f32 = 0,

    pub const _desc_table = .{
        .sfixed64 = fd(1, .{ .FixedInt = .I64 }),
        .sfixed32 = fd(2, .{ .FixedInt = .I32 }),
        .fixed32 = fd(3, .{ .FixedInt = .I32 }),
        .fixed64 = fd(4, .{ .FixedInt = .I64 }),
        .double = fd(5, .{ .FixedInt = .I64 }),
        .float = fd(6, .{ .FixedInt = .I32 }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const TopLevelEnum = enum(i32) {
    SE_ZERO = 0,
    SE2_ZERO = 3,
    SE2_ONE = 4,
    _,
};

pub const WithEnum = struct {
    value: SomeEnum = @enumFromInt(0),

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub const SomeEnum = enum(i32) {
        SE_ZERO = 0,
        SE_ONE = 1,
        A = 3,
        B = 4,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithEnumShadow = struct {
    value: SomeEnum = @enumFromInt(0),

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub const SomeEnum = enum(i32) {
        SE_ZERO = 0,
        SE2_ZERO = 3,
        SE2_ONE = 4,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const RepeatedEnum = struct {
    value: ArrayList(TopLevelEnum),

    pub const _desc_table = .{
        .value = fd(1, .{ .List = .{ .Varint = .Simple } }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const Packed = struct {
    int32_list: ArrayList(i32),
    uint32_list: ArrayList(u32),
    sint32_list: ArrayList(i32),
    float_list: ArrayList(f32),
    double_list: ArrayList(f64),
    int64_list: ArrayList(i64),
    sint64_list: ArrayList(i64),
    uint64_list: ArrayList(u64),
    bool_list: ArrayList(bool),
    enum_list: ArrayList(TopLevelEnum),

    pub const _desc_table = .{
        .int32_list = fd(1, .{ .PackedList = .{ .Varint = .Simple } }),
        .uint32_list = fd(2, .{ .PackedList = .{ .Varint = .Simple } }),
        .sint32_list = fd(3, .{ .PackedList = .{ .Varint = .ZigZagOptimized } }),
        .float_list = fd(4, .{ .PackedList = .{ .FixedInt = .I32 } }),
        .double_list = fd(5, .{ .PackedList = .{ .FixedInt = .I64 } }),
        .int64_list = fd(6, .{ .PackedList = .{ .Varint = .Simple } }),
        .sint64_list = fd(7, .{ .PackedList = .{ .Varint = .ZigZagOptimized } }),
        .uint64_list = fd(8, .{ .PackedList = .{ .Varint = .Simple } }),
        .bool_list = fd(9, .{ .PackedList = .{ .Varint = .Simple } }),
        .enum_list = fd(10, .{ .PackedList = .{ .Varint = .Simple } }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const UnPacked = struct {
    int32_list: ArrayList(i32),
    uint32_list: ArrayList(u32),
    sint32_list: ArrayList(i32),
    float_list: ArrayList(f32),
    double_list: ArrayList(f64),
    int64_list: ArrayList(i64),
    sint64_list: ArrayList(i64),
    uint64_list: ArrayList(u64),
    bool_list: ArrayList(bool),
    enum_list: ArrayList(TopLevelEnum),

    pub const _desc_table = .{
        .int32_list = fd(1, .{ .List = .{ .Varint = .Simple } }),
        .uint32_list = fd(2, .{ .List = .{ .Varint = .Simple } }),
        .sint32_list = fd(3, .{ .List = .{ .Varint = .ZigZagOptimized } }),
        .float_list = fd(4, .{ .List = .{ .FixedInt = .I32 } }),
        .double_list = fd(5, .{ .List = .{ .FixedInt = .I64 } }),
        .int64_list = fd(6, .{ .List = .{ .Varint = .Simple } }),
        .sint64_list = fd(7, .{ .List = .{ .Varint = .ZigZagOptimized } }),
        .uint64_list = fd(8, .{ .List = .{ .Varint = .Simple } }),
        .bool_list = fd(9, .{ .List = .{ .Varint = .Simple } }),
        .enum_list = fd(10, .{ .List = .{ .Varint = .Simple } }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithSubmessages = struct {
    with_enum: ?WithEnum = null,

    pub const _desc_table = .{
        .with_enum = fd(1, .{ .SubMessage = {} }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithStrings = struct {
    name: ManagedString = .Empty,

    pub const _desc_table = .{
        .name = fd(1, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithRepeatedStrings = struct {
    name: ArrayList(ManagedString),

    pub const _desc_table = .{
        .name = fd(1, .{ .List = .String }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithBytes = struct {
    byte_field: ManagedString = .Empty,

    pub const _desc_table = .{
        .byte_field = fd(1, .Bytes),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const WithRepeatedBytes = struct {
    byte_field: ArrayList(ManagedString),

    pub const _desc_table = .{
        .byte_field = fd(1, .{ .List = .Bytes }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
