const pb_fixedsizes = @import("fixedsizes.pb.zig");
const FixedSizes = pb_fixedsizes.FixedSizes;

const std = @import("std");
const testing = std.testing;

test "FixedSizes" {
    var demo = FixedSizes{
        .sfixed64 = -1,
        .sfixed32 = -2,
        .fixed32 = 1,
        .fixed64 = 2,
        .double = 5.0, // 0x4014000000000000
        .float = 5.0, // 0x40a00000
    };

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    const expected = [_]u8{ 0x08 + 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x10 + 5, 0xFE, 0xFF, 0xFF, 0xFF, 0x18 + 5, 0x01, 0x00, 0x00, 0x00, 0x20 + 1, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28 + 1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x40, 0x30 + 5, 0x00, 0x00, 0xa0, 0x40 };

    try testing.expectEqualSlices(u8, &expected, obtained);

    // decoding
    const decoded = try FixedSizes.decode(&expected, testing.allocator);
    try testing.expectEqual(demo, decoded);
}