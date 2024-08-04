const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Packed = @import("../../generated/tests.pb.zig").Packed;


pub fn get(allocator: Allocator) !Packed {
    var instance = Packed.init(allocator);

    try instance.int32_list.append(-1);
    try instance.int32_list.append(2);
    try instance.int32_list.append(3);

    try instance.uint32_list.append(1);
    try instance.uint32_list.append(2);
    try instance.uint32_list.append(3);

    try instance.sint32_list.append(2);
    try instance.sint32_list.append(3);
    try instance.sint32_list.append(4);

    try instance.float_list.append(1.0);
    try instance.float_list.append(-1_000.0);
    try instance.float_list.append(std.math.nan(f32));
    try instance.float_list.append(std.math.inf(f32));

    try instance.double_list.append(2.1);
    try instance.double_list.append(-1_000.0);
    try instance.double_list.append(-std.math.inf(f64));

    try instance.int64_list.append(3);
    try instance.int64_list.append(-4);
    try instance.int64_list.append(5);

    try instance.sint64_list.append(-4);
    try instance.sint64_list.append(5);
    try instance.sint64_list.append(-6);

    try instance.uint64_list.append(5);
    try instance.uint64_list.append(6);
    try instance.uint64_list.append(7);

    try instance.bool_list.append(true);
    try instance.bool_list.append(false);
    try instance.bool_list.append(false);

    try instance.enum_list.append(.SE_ZERO);
    try instance.enum_list.append(.SE2_ONE);

    return instance;
}

pub fn get2(allocator: Allocator) !Packed {
    var instance = Packed.init(allocator);

    try instance.int32_list.append(-1);
    try instance.int32_list.append(2);
    try instance.int32_list.append(3);

    try instance.float_list.append(1.0);
    try instance.float_list.append(-1_000.0);
    try instance.float_list.append(std.math.nan(f32));
    try instance.float_list.append(std.math.inf(f32));

    return instance;
}
