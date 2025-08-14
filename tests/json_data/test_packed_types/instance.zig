const std = @import("std");
const math = std.math;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const TestPackedTypes = @import("../../generated/unittest.pb.zig").TestPackedTypes;

pub fn get(allocator: Allocator) !TestPackedTypes {
    var instance = try TestPackedTypes.init(allocator);
    try instance.packed_float.append(allocator, 1.0);
    try instance.packed_double.append(allocator, 1.0);
    try instance.packed_float.append(allocator, math.nan(f32));
    try instance.packed_double.append(allocator, math.nan(f64));
    try instance.packed_float.append(allocator, math.inf(f32));
    try instance.packed_double.append(allocator, math.inf(f64));
    try instance.packed_float.append(allocator, -math.inf(f32));
    try instance.packed_double.append(allocator, -math.inf(f64));
    try instance.packed_float.append(allocator, 1.0);
    try instance.packed_double.append(allocator, 1.0);

    return instance;
}
