const std = @import("std");

const oneof_zig = @import("../../generated/tests/oneof.pb.zig");
const OneofContainer = oneof_zig.OneofContainer;

pub fn get(allocator: std.mem.Allocator) !OneofContainer {
    return OneofContainer{
        .some_oneof = .{
            .string_in_oneof = try allocator.dupe(
                u8,
                "testing oneof field being the string",
            ),
        },
        .regular_field = try allocator.dupe(
            u8,
            "this field is always the same",
        ),
        .enum_field = .UNSPECIFIED,
    };
}
