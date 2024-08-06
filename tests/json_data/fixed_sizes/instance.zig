const FixedSizes = @import("../../generated/tests.pb.zig").FixedSizes;

pub fn get() FixedSizes {
    return FixedSizes{
        .sfixed64 = 1,
        .sfixed32 = 2,
        .fixed32 = 3,
        .fixed64 = 4,
        .double = 5.0,
        .float = 6.0,
    };
}
