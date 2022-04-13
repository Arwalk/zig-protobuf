const std = @import("std");
const pb_varints = @import("varints.pb.zig");
const Varints = pb_varints.Varints;
const testing = std.testing;


test "Varints" {
    var demo = Varints.init(testing.allocator);
    defer demo.deinit();
    demo.sint32 = -1;
    demo.sint64 = -1;
    demo.uint32 = 150; 
    demo.uint64 = 150; 
    demo.a_bool = true;
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01}, obtained);

    const decoded = try Varints.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqual(demo, decoded);
}