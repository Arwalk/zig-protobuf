const ManagedString = @import("protobuf").ManagedString;
const oneof_zig = @import("../../generated/tests/oneof.pb.zig");
const OneofContainer = oneof_zig.OneofContainer;
const Message = oneof_zig.Message;

pub fn get() OneofContainer {
    return OneofContainer{
        .some_oneof = .{
            .message_in_oneof = Message{
                .str = ManagedString.static(
                    "that's a string inside message_in_oneof",
                ),
                .value = -17,
            },
        },
        .regular_field = ManagedString.static(
            "this field is always the same",
        ),
        .enum_field = .UNSPECIFIED,
    };
}
