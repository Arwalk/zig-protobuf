// Code generated by protoc-gen-zig
///! package tests.oneof
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;
const ManagedStruct = protobuf.ManagedStruct;

pub const Enum = enum(i32) {
    UNSPECIFIED = 0,
    SOMETHING = 1,
    SOMETHING2 = 2,
    _,
};

pub const Message = struct {
    value: i32 = 0,
    str: ManagedString = .Empty,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
        .str = fd(2, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const OneofContainer = struct {
    regular_field: ManagedString = .Empty,
    enum_field: Enum = @enumFromInt(0),
    some_oneof: ?some_oneof_union,

    pub const _some_oneof_case = enum {
        string_in_oneof,
        message_in_oneof,
        a_number,
        enum_value,
    };
    pub const some_oneof_union = union(_some_oneof_case) {
        string_in_oneof: ManagedString,
        message_in_oneof: Message,
        a_number: i32,
        enum_value: Enum,
        pub const _union_desc = .{
            .string_in_oneof = fd(1, .String),
            .message_in_oneof = fd(2, .{ .SubMessage = {} }),
            .a_number = fd(3, .{ .Varint = .Simple }),
            .enum_value = fd(6, .{ .Varint = .Simple }),
        };
    };

    pub const _desc_table = .{
        .regular_field = fd(4, .String),
        .enum_field = fd(5, .{ .Varint = .Simple }),
        .some_oneof = fd(null, .{ .OneOf = some_oneof_union }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
