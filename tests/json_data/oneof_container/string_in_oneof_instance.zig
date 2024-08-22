const ManagedString = @import("protobuf").ManagedString;
const oneof_zig = @import("../../generated/tests/oneof.pb.zig");
const OneofContainer = oneof_zig.OneofContainer;

pub fn get() OneofContainer {
    return OneofContainer{
        .some_oneof = .{
            .string_in_oneof = ManagedString.static(
                "testing oneof field being the string",
            ),
        },
        .regular_field = ManagedString.static(
            "this field is always the same",
        ),
        .enum_field = .UNSPECIFIED,
    };
}
