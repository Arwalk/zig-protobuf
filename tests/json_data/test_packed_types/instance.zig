const std = @import("std");
const math = std.math;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const TestPackedTypes = @import("../../generated/unittest.pb.zig").TestPackedTypes;

pub fn get(allocator: Allocator) !TestPackedTypes {
    var instance = TestPackedTypes.init(allocator);
    try instance.packed_float.append(1.0);
    try instance.packed_double.append(1.0);
    try instance.packed_float.append(math.nan(f32));
    try instance.packed_double.append(math.nan(f64));
    try instance.packed_float.append(math.inf(f32));
    try instance.packed_double.append(math.inf(f64));
    try instance.packed_float.append(-math.inf(f32));
    try instance.packed_double.append(-math.inf(f64));
    try instance.packed_float.append(1.0);
    try instance.packed_double.append(1.0);

    return instance;
}
