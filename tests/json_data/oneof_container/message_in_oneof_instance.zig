const std = @import("std");

const oneof_zig = @import("../../generated/tests/oneof.pb.zig");
const OneofContainer = oneof_zig.OneofContainer;
const Message = oneof_zig.Message;

pub fn get(allocator: std.mem.Allocator) !OneofContainer {
    return OneofContainer{
        .some_oneof = .{
            .message_in_oneof = Message{
                .str = try allocator.dupe(
                    u8,
                    "that's a string inside message_in_oneof",
                ),
                .value = -17,
            },
        },
        .regular_field = try allocator.dupe(
            u8,
            "this field is always the same",
        ),
        .enum_field = .UNSPECIFIED,
    };
}
