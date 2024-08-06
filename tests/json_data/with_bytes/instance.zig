const ManagedString = @import("protobuf").ManagedString;
const WithBytes = @import("../../generated/tests.pb.zig").WithBytes;

pub fn get() WithBytes {
    return WithBytes{
        .byte_field = ManagedString.static(
            // base64-encoded string is "yv7K/g=="
            &[_]u8{ 0xCA, 0xFE, 0xCA, 0xFE },
        ),
    };
}
