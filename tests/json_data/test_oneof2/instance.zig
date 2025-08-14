const std = @import("std");

const TestOneof2 = @import("../../generated/unittest.pb.zig").TestOneof2;

pub fn get(allocator: std.mem.Allocator) !TestOneof2 {
    return TestOneof2{
        .baz_int = 15,
        .baz_string = try allocator.dupe(
            u8,
            "we're here to check if oneof.Bytes will be serialized correctly",
        ),
        .foo = .{ .foo_bytes = try allocator.dupe(u8, "some bytes to check it") },
        .bar = .{ .bar_int = 151515 },
    };
}
