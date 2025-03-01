const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const common = @import("./generated/opentelemetry/proto/common/v1.pb.zig");
const benchmark_data = @import("./generated/benchmark.pb.zig");
const ArrayList = std.ArrayList;
const AllocatorError = std.mem.Allocator.Error;

pub fn generateRandomManagedString(allocator: std.mem.Allocator) AllocatorError![]const u8 {
    // 50% chance of returning Empty
    if (std.crypto.random.boolean()) {
        return "";
    }

    // Generate random string length between 1-20 chars
    const len = std.crypto.random.intRangeAtMost(usize, 1, 20);

    var str = try allocator.alloc(u8, len);

    // Fill with random ASCII letters
    for (0..len) |i| {
        str[i] = std.crypto.random.intRangeAtMost(u8, 'a', 'z');
    }

    return str;
}

fn generateRandomAnyValue(allocator: std.mem.Allocator) AllocatorError!common.AnyValue {
    const value_case = std.crypto.random.intRangeAtMost(usize, 0, 6);
    const to_enum: common.AnyValue._value_case = @enumFromInt(value_case);

    return switch (to_enum) {
        .string_value => .{ .value = .{ .string_value = try generateRandomManagedString(allocator) } },
        .bool_value => .{ .value = .{ .bool_value = std.crypto.random.boolean() } },
        .int_value => .{ .value = .{ .int_value = std.crypto.random.int(i64) } },
        .double_value => .{ .value = .{ .double_value = std.crypto.random.float(f64) } },
        .array_value => .{ .value = .{ .array_value = try generateRandomArrayValue(allocator) } },
        .kvlist_value => .{ .value = .{ .kvlist_value = try generateRandomKeyValueList(allocator) } },
        .bytes_value => .{ .value = .{ .bytes_value = try generateRandomManagedString(allocator) } },
    };
}

fn generateRandomArrayValue(allocator: std.mem.Allocator) AllocatorError!common.ArrayValue {
    var list: common.ArrayValue = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.values.append(allocator, try generateRandomAnyValue(allocator));
    }

    return list;
}

fn generateRandomKeyValueList(allocator: std.mem.Allocator) AllocatorError!common.KeyValueList {
    var list: common.KeyValueList = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.values.append(allocator, try generateRandomKeyValue(allocator));
    }

    return list;
}

fn generateRandomKeyValue(allocator: std.mem.Allocator) AllocatorError!common.KeyValue {
    const value: ?common.AnyValue = if (std.crypto.random.boolean())
        try generateRandomAnyValue(allocator)
    else
        null;

    return common.KeyValue{ .key = try generateRandomManagedString(allocator), .value = value };
}

fn generateRandomBuckets(allocator: std.mem.Allocator) AllocatorError!metrics.ExponentialHistogramDataPoint.Buckets {
    var buckets: metrics.ExponentialHistogramDataPoint.Buckets = .{};
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try buckets.bucket_counts.append(allocator, std.crypto.random.int(u64));
    }

    buckets.offset = std.crypto.random.int(i32);

    return buckets;
}

fn nullOrItem(comptime T: type, function: anytype, allocator: std.mem.Allocator) AllocatorError!?T {
    if (std.crypto.random.boolean()) {
        return try function(allocator);
    } else {
        return null;
    }
}

fn generateRandomExemplar(allocator: std.mem.Allocator) AllocatorError!metrics.Exemplar {
    var exemplar: metrics.Exemplar = .{};
    exemplar.filtered_attributes = (try generateRandomKeyValueList(allocator)).values;
    exemplar.time_unix_nano = std.crypto.random.int(u64);
    exemplar.span_id = try generateRandomManagedString(allocator);
    exemplar.trace_id = try generateRandomManagedString(allocator);
    return exemplar;
}

fn generateRandomExemplarList(allocator: std.mem.Allocator) AllocatorError!ArrayList(metrics.Exemplar) {
    var list: ArrayList(metrics.Exemplar) = .empty;
    const count = std.crypto.random.intRangeAtMost(usize, 0, 5);
    for (0..count) |_| {
        try list.append(allocator, try generateRandomExemplar(allocator));
    }

    return list;
}

pub fn generateRandomExponentialHistogramDataPoint(allocator: std.mem.Allocator) AllocatorError!metrics.ExponentialHistogramDataPoint {
    // Initialize the point
    var point: metrics.ExponentialHistogramDataPoint = .{};

    point.attributes = (try generateRandomKeyValueList(allocator)).values;
    point.start_time_unix_nano = std.crypto.random.int(u64);
    point.time_unix_nano = std.crypto.random.int(u64);
    point.count = std.crypto.random.int(u64);
    point.sum = std.crypto.random.float(f64);
    point.scale = std.crypto.random.int(i32);
    point.zero_count = std.crypto.random.int(u64);

    point.positive = try nullOrItem(metrics.ExponentialHistogramDataPoint.Buckets, generateRandomBuckets, allocator);
    point.negative = try nullOrItem(metrics.ExponentialHistogramDataPoint.Buckets, generateRandomBuckets, allocator);

    point.flags = std.crypto.random.int(u32);
    point.exemplars = try generateRandomExemplarList(allocator);
    point.min = std.crypto.random.float(f64);
    point.max = std.crypto.random.float(f64);
    point.zero_threshold = std.crypto.random.float(f64);

    return point;
}

const DATASET_SIZE = 100;
const OUTPUT_FILENAME = "test.data";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Create a BenchmarkData instance with 100 random histogram points
    var data: benchmark_data.BenchmarkData = .{};
    std.debug.print("Generating {d} random ExponentialHistogramDataPoint entries...\n", .{DATASET_SIZE});

    for (0..DATASET_SIZE) |i| {
        if (i % 10 == 0) {
            std.debug.print("Generated {d}/{d} entries\n", .{ i, DATASET_SIZE });
        }
        try data.histogram_points.append(arena_allocator, try generateRandomExponentialHistogramDataPoint(arena_allocator));
    }

    // Encode the data to a file
    std.debug.print("Encoding data...\n", .{});
    var w: std.Io.Writer.Allocating = .init(arena_allocator);
    defer w.deinit();
    try data.encode(&w.writer, arena_allocator);
    const encoded_data = w.written();

    // Write to file
    std.debug.print("Writing to file: {s}...\n", .{OUTPUT_FILENAME});
    const file = try std.fs.cwd().createFile(OUTPUT_FILENAME, .{});
    defer file.close();

    try file.writeAll(encoded_data);

    std.debug.print("Dataset generation complete: {d} bytes written to {s}\n", .{ encoded_data.len, OUTPUT_FILENAME });
}
