const std = @import("std");
const tests = @import("./.generated/generated_in_ci.pb.zig");
const testing = std.testing;

test "Varints" {
    var demo = tests.Varints.init(testing.allocator);
    defer demo.deinit();
    demo.sint32 = -1;
    demo.sint64 = -1;
    demo.uint32 = 150;
    demo.uint64 = 150;
    demo.a_bool = true;
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01 }, obtained);

    const decoded = try tests.Varints.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqual(demo, decoded);
}

test "Varints - encode/decode equivalence" {
    var demo = tests.Varints.init(testing.allocator);
    defer demo.deinit();
    demo.sint32 = -105;
    demo.sint64 = -11119487612;
    demo.uint32 = 923658273;
    demo.uint64 = 1512312313130;
    demo.a_bool = true;

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    const decoded = try tests.Varints.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualDeep(demo, decoded);
}
