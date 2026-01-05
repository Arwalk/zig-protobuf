const std = @import("std");
const protobuf = @import("protobuf");
const logs = @import("generated/opentelemetry/proto/logs/v1.pb.zig");
const common = @import("generated/opentelemetry/proto/common/v1.pb.zig");

const NUM_LOG_RECORDS = 1000;
const NUM_ATTRIBUTES = 10;
const NUM_ITERATIONS = 500;

fn createTestLogsData(allocator: std.mem.Allocator) !logs.LogsData {
    var logs_data: logs.LogsData = .{};

    // Create one ResourceLogs with one ScopeLogs containing many LogRecords
    try logs_data.resource_logs.append(allocator, .{
        .schema_url = "https://opentelemetry.io/schemas/1.0.0",
    });

    var resource_logs = &logs_data.resource_logs.items[0];
    try resource_logs.scope_logs.append(allocator, .{
        .schema_url = "https://opentelemetry.io/schemas/1.0.0",
    });

    var scope_logs = &resource_logs.scope_logs.items[0];
    scope_logs.scope = .{
        .name = "test-scope",
        .version = "1.0.0",
    };

    // Pre-allocate for all log records
    try scope_logs.log_records.ensureTotalCapacity(allocator, NUM_LOG_RECORDS);

    for (0..NUM_LOG_RECORDS) |i| {
        var log_record: logs.LogRecord = .{
            .time_unix_nano = 1704067200000000000 + i * 1000000, // fixed64
            .observed_time_unix_nano = 1704067200000000000 + i * 1000000 + 100, // fixed64
            .severity_number = .SEVERITY_NUMBER_INFO,
            .severity_text = "INFO",
            .flags = 0x00000001, // fixed32
            .trace_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 },
            .span_id = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        };

        // Add body
        log_record.body = .{
            .value = .{ .string_value = "This is a test log message with some content" },
        };

        // Add attributes
        try log_record.attributes.ensureTotalCapacity(allocator, NUM_ATTRIBUTES);
        for (0..NUM_ATTRIBUTES) |j| {
            _ = j;
            log_record.attributes.appendAssumeCapacity(.{
                .key = "attribute_key",
                .value = .{
                    .value = .{ .string_value = "attribute_value" },
                },
            });
        }

        scope_logs.log_records.appendAssumeCapacity(log_record);
    }

    return logs_data;
}

fn encodeLogsData(logs_data: *const logs.LogsData, allocator: std.mem.Allocator) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    try logs_data.encode(&w.writer, allocator);
    return w.written();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== OTLP Logs Benchmark ===\n", .{});
    std.debug.print("Log records: {d}\n", .{NUM_LOG_RECORDS});
    std.debug.print("Attributes per record: {d}\n", .{NUM_ATTRIBUTES});
    std.debug.print("Iterations: {d}\n\n", .{NUM_ITERATIONS});

    // Create and encode test data
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const test_data = try createTestLogsData(arena.allocator());
    const encoded = try encodeLogsData(&test_data, arena.allocator());

    std.debug.print("Encoded size: {d} bytes\n\n", .{encoded.len});

    // Benchmark decoding
    var total_decode_time: u64 = 0;
    var min_decode_time: u64 = std.math.maxInt(u64);
    var max_decode_time: u64 = 0;

    for (0..NUM_ITERATIONS) |_| {
        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();

        var reader: std.Io.Reader = .fixed(encoded);

        const start = std.time.nanoTimestamp();
        const decoded = try logs.LogsData.decode(&reader, decode_arena.allocator());
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_decode_time += elapsed;
        min_decode_time = @min(min_decode_time, elapsed);
        max_decode_time = @max(max_decode_time, elapsed);

        // Verify decode worked
        if (decoded.resource_logs.items.len != 1) {
            return error.DecodeFailed;
        }
    }

    const avg_decode_time = total_decode_time / NUM_ITERATIONS;
    const throughput_msgs_per_sec = @as(f64, @floatFromInt(NUM_ITERATIONS * NUM_LOG_RECORDS)) /
        (@as(f64, @floatFromInt(total_decode_time)) / 1_000_000_000.0);
    const throughput_mb_per_sec = (@as(f64, @floatFromInt(NUM_ITERATIONS)) * @as(f64, @floatFromInt(encoded.len))) /
        (@as(f64, @floatFromInt(total_decode_time)) / 1_000_000_000.0) / (1024.0 * 1024.0);

    std.debug.print("=== Decode Results ===\n", .{});
    std.debug.print("Average: {d:.3} ms\n", .{@as(f64, @floatFromInt(avg_decode_time)) / 1_000_000.0});
    std.debug.print("Min:     {d:.3} ms\n", .{@as(f64, @floatFromInt(min_decode_time)) / 1_000_000.0});
    std.debug.print("Max:     {d:.3} ms\n", .{@as(f64, @floatFromInt(max_decode_time)) / 1_000_000.0});
    std.debug.print("Throughput: {d:.0} log records/sec\n", .{throughput_msgs_per_sec});
    std.debug.print("Throughput: {d:.2} MB/sec\n", .{throughput_mb_per_sec});

    // Also benchmark encoding
    var total_encode_time: u64 = 0;
    var min_encode_time: u64 = std.math.maxInt(u64);
    var max_encode_time: u64 = 0;

    for (0..NUM_ITERATIONS) |_| {
        var encode_arena = std.heap.ArenaAllocator.init(allocator);
        defer encode_arena.deinit();

        var w: std.Io.Writer.Allocating = .init(encode_arena.allocator());

        const start = std.time.nanoTimestamp();
        try test_data.encode(&w.writer, encode_arena.allocator());
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_encode_time += elapsed;
        min_encode_time = @min(min_encode_time, elapsed);
        max_encode_time = @max(max_encode_time, elapsed);
    }

    const avg_encode_time = total_encode_time / NUM_ITERATIONS;
    const encode_throughput_msgs_per_sec = @as(f64, @floatFromInt(NUM_ITERATIONS * NUM_LOG_RECORDS)) /
        (@as(f64, @floatFromInt(total_encode_time)) / 1_000_000_000.0);

    std.debug.print("\n=== Encode Results ===\n", .{});
    std.debug.print("Average: {d:.3} ms\n", .{@as(f64, @floatFromInt(avg_encode_time)) / 1_000_000.0});
    std.debug.print("Min:     {d:.3} ms\n", .{@as(f64, @floatFromInt(min_encode_time)) / 1_000_000.0});
    std.debug.print("Max:     {d:.3} ms\n", .{@as(f64, @floatFromInt(max_encode_time)) / 1_000_000.0});
    std.debug.print("Throughput: {d:.0} log records/sec\n", .{encode_throughput_msgs_per_sec});
}

test "benchmark_decode" {
    // This allows running via `zig build test`
    try main();
}
