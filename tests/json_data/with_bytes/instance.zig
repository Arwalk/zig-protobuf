const std = @import("std");

const WithBytes = @import("../../generated/tests.pb.zig").WithBytes;

pub fn get(allocator: std.mem.Allocator) !WithBytes {
    return WithBytes{
        .byte_field = try allocator.dupe(
            u8,
            // base64-encoded string is "yv7K/g=="
            &[_]u8{ 0xCA, 0xFE, 0xCA, 0xFE },
        ),
    };
}
