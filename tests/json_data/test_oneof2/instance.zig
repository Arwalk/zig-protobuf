const math = @import("std").math;
const ManagedString = @import("protobuf").ManagedString;
const TestOneof2 = @import("../../generated/unittest.pb.zig").TestOneof2;

pub fn get() TestOneof2 {
    return TestOneof2{
        .baz_int = 15,
        .baz_string = ManagedString.static(
            "we're here to check if oneof.Bytes will be serialized correctly",
        ),
        .foo = .{ .foo_bytes = ManagedString.static("some bytes to check it") },
        .bar = .{ .bar_int = 151515 },
    };
}
