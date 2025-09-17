const FixedSizes = @import("./generated/tests.pb.zig").FixedSizes;

const std = @import("std");

test "FixedSizes" {
    var demo: FixedSizes = .{};
    defer demo.deinit(std.testing.allocator);
    demo.sfixed64 = -1;
    demo.sfixed32 = -2;
    demo.fixed32 = 1;
    demo.fixed64 = 2;
    demo.double = 5.0; // 0x4014000000000000
    demo.float = 5.0; // 0x40a00000

    const expected: []const u8 = &.{ 0x08 + 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x10 + 5, 0xFE, 0xFF, 0xFF, 0xFF, 0x18 + 5, 0x01, 0x00, 0x00, 0x00, 0x20 + 1, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28 + 1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x40, 0x30 + 5, 0x00, 0x00, 0xa0, 0x40 };

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, expected, w.written());

    // decoding
    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try FixedSizes.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(demo, decoded);
}

test "FixedSizes - encode/decode" {
    var demo: FixedSizes = .{};
    defer demo.deinit(std.testing.allocator);
    demo.sfixed64 = -1123123141;
    demo.sfixed32 = -2131312;
    demo.fixed32 = 1;
    demo.fixed64 = 2;
    demo.double = 5.0;
    demo.float = 5.0;

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, std.testing.allocator);

    // decoding
    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try FixedSizes.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(demo, decoded);
}
