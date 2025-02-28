const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const common = @import("./generated/opentelemetry/proto/common/v1.pb.zig");
const zbench = @import("zbench");
const ArrayList = std.ArrayList;
const AllocatorError = std.mem.Allocator.Error;

fn generateRandomManagedString() AllocatorError![]const u8 {
    // 50% chance of returning Empty
    if (std.crypto.random.boolean()) {
        return "";
    }

    // Generate random string length between 1-20 chars
    const len = std.crypto.random.intRangeAtMost(usize, 1, 20);

    var str = try allocator_for_tests.alloc(u8, len);

    // Fill with random ASCII letters
    for (0..len) |i| {
        str[i] = std.crypto.random.intRangeAtMost(u8, 'a', 'z');
    }

    return str;
}

fn generateRandomAnyValue() AllocatorError!common.AnyValue {
    const value_case = std.crypto.random.intRangeAtMost(usize, 0, 6);
    const to_enum: common.AnyValue._value_case = @enumFromInt(value_case);

    return switch (to_enum) {
        .string_value => .{ .value = .{ .string_value = try generateRandomManagedString() } },
        .bool_value => .{ .value = .{ .bool_value = std.crypto.random.boolean() } },
        .int_value => .{ .value = .{ .int_value = std.crypto.random.int(i64) } },
        .double_value => .{ .value = .{ .double_value = std.crypto.random.float(f64) } },
        .array_value => .{ .value = .{ .array_value = try generateRandomArrayValue() } },
        .kvlist_value => .{ .value = .{ .kvlist_value = try generateRandomKeyValueList() } },
        .bytes_value => .{ .value = .{ .bytes_value = try generateRandomManagedString() } },
    };
}

fn generateRandomArrayValue() AllocatorError!common.ArrayValue {
    var list: common.ArrayValue = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.values.append(allocator_for_tests, try generateRandomAnyValue());
    }

    return list;
}

fn generateRandomKeyValueList() AllocatorError!common.KeyValueList {
    var list: common.KeyValueList = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.values.append(allocator_for_tests, try generateRandomKeyValue());
    }

    return list;
}

fn generateRandomKeyValue() AllocatorError!common.KeyValue {
    const value: ?common.AnyValue = if (std.crypto.random.boolean())
        try generateRandomAnyValue()
    else
        null;

    return common.KeyValue{ .key = try generateRandomManagedString(), .value = value };
}

fn generateRandomBuckets() AllocatorError!metrics.ExponentialHistogramDataPoint.Buckets {
    var buckets: metrics.ExponentialHistogramDataPoint.Buckets = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try buckets.bucket_counts.append(allocator_for_tests, std.crypto.random.int(u64));
    }

    buckets.offset = std.crypto.random.int(i32);

    return buckets;
}

fn nullOrItem(comptime T: type, function: anytype) AllocatorError!?T {
    if (std.crypto.random.boolean()) {
        return try function();
    } else {
        return null;
    }
}

fn generateRandomExemplar() AllocatorError!metrics.Exemplar {
    var exemplar: metrics.Exemplar = .{};
    exemplar.filtered_attributes = (try generateRandomKeyValueList()).values;
    exemplar.time_unix_nano = std.crypto.random.int(u64);
    exemplar.span_id = try generateRandomManagedString();
    exemplar.trace_id = try generateRandomManagedString();
    return exemplar;
}

fn generateRandomExemplarList() AllocatorError!ArrayList(metrics.Exemplar) {
    var list: ArrayList(metrics.Exemplar) = .empty;
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.append(allocator_for_tests, try generateRandomExemplar());
    }

    return list;
}

pub fn generateRandomExponentialHistogramDataPoint() AllocatorError!metrics.ExponentialHistogramDataPoint {
    // Initialize the point
    var point: metrics.ExponentialHistogramDataPoint = .{};

    point.attributes = (try generateRandomKeyValueList()).values;
    point.start_time_unix_nano = std.crypto.random.int(u64);
    point.time_unix_nano = std.crypto.random.int(u64);
    point.count = std.crypto.random.int(u64);
    point.sum = std.crypto.random.float(f64);
    point.scale = std.crypto.random.int(i32);
    point.zero_count = std.crypto.random.int(u64);

    point.positive = try nullOrItem(metrics.ExponentialHistogramDataPoint.Buckets, generateRandomBuckets);
    point.negative = try nullOrItem(metrics.ExponentialHistogramDataPoint.Buckets, generateRandomBuckets);

    point.flags = std.crypto.random.int(u32);
    point.exemplars = try generateRandomExemplarList();
    point.min = std.crypto.random.float(f64);
    point.max = std.crypto.random.float(f64);
    point.zero_threshold = std.crypto.random.float(f64);

    return point;
}

fn bench_encode(allocator: std.mem.Allocator) void {
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    _ = input_to_encode.encode(&w.writer, allocator) catch null;
}

fn bench_decode(allocator: std.mem.Allocator) void {
    var reader: std.Io.Reader = .fixed(input_to_decode);
    _ = metrics.ExponentialHistogramDataPoint.decode(&reader, allocator) catch null;
}

fn regenInputs() void {
    input_to_encode = generateRandomExponentialHistogramDataPoint() catch unreachable;
    var w: std.Io.Writer.Allocating = .init(allocator_for_tests);
    defer w.deinit();
    input_to_encode.encode(&w.writer, allocator_for_tests) catch unreachable;
    input_to_decode = w.written();
}

const size: usize = 1;

var input_to_encode: metrics.ExponentialHistogramDataPoint = undefined;
var input_to_decode: []u8 = undefined;
var allocator_for_tests: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    allocator_for_tests = arena_allocator;

    regenInputs();

    var bench = zbench.Benchmark.init(arena_allocator, .{});
    defer bench.deinit();

    try bench.add("encoding benchmark", bench_encode, .{ .hooks = .{ .before_each = regenInputs } });
    try bench.add("decoding benchmark", bench_decode, .{ .hooks = .{ .before_each = regenInputs } });

    var buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const writer = &stderr.interface;
    try bench.run(writer);
    try writer.flush();
}
