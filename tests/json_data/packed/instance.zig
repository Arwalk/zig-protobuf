const std = @import("std");
const ArrayList = std.ArrayList;
const Packed = @import("../../generated/tests.pb.zig").Packed;

pub fn get(allocator: std.mem.Allocator) !Packed {
    var instance: Packed = .{};

    try instance.int32_list.append(allocator, -1);
    try instance.int32_list.append(allocator, 2);
    try instance.int32_list.append(allocator, 3);

    try instance.uint32_list.append(allocator, 1);
    try instance.uint32_list.append(allocator, 2);
    try instance.uint32_list.append(allocator, 3);

    try instance.sint32_list.append(allocator, 2);
    try instance.sint32_list.append(allocator, 3);
    try instance.sint32_list.append(allocator, 4);

    try instance.float_list.append(allocator, 1.0);
    try instance.float_list.append(allocator, -1_000.0);
    try instance.float_list.append(allocator, std.math.nan(f32));
    try instance.float_list.append(allocator, std.math.inf(f32));

    try instance.double_list.append(allocator, 2.1);
    try instance.double_list.append(allocator, -1_000.0);
    try instance.double_list.append(allocator, -std.math.inf(f64));

    try instance.int64_list.append(allocator, 3);
    try instance.int64_list.append(allocator, -4);
    try instance.int64_list.append(allocator, 5);

    try instance.sint64_list.append(allocator, -4);
    try instance.sint64_list.append(allocator, 5);
    try instance.sint64_list.append(allocator, -6);

    try instance.uint64_list.append(allocator, 5);
    try instance.uint64_list.append(allocator, 6);
    try instance.uint64_list.append(allocator, 7);

    try instance.bool_list.append(allocator, true);
    try instance.bool_list.append(allocator, false);
    try instance.bool_list.append(allocator, false);

    try instance.enum_list.append(allocator, .SE_ZERO);
    try instance.enum_list.append(allocator, .SE2_ONE);

    return instance;
}

pub fn get2(allocator: std.mem.Allocator) !Packed {
    var instance: Packed = .{};

    try instance.int32_list.append(allocator, -1);
    try instance.int32_list.append(allocator, 2);
    try instance.int32_list.append(allocator, 3);

    try instance.float_list.append(allocator, 1.0);
    try instance.float_list.append(allocator, -1_000.0);
    try instance.float_list.append(allocator, std.math.nan(f32));
    try instance.float_list.append(allocator, std.math.inf(f32));

    return instance;
}
