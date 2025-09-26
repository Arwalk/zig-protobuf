const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const benchmark_data = @import("./generated/benchmark.pb.zig");
const zbench = @import("zbench");
const dataset_generator = @import("./generate_dataset.zig");

const DATASET_FILENAME = "test.data";

fn bench_encode(allocator: std.mem.Allocator) void {
    var w: std.Io.Writer.Allocating = .init(allocator);
    _ = input_to_encode.encode(&w.writer, allocator) catch null;
}

fn bench_decode(allocator: std.mem.Allocator) void {
    var reader: std.Io.Reader = .fixed(input_to_decode);
    _ = metrics.ExponentialHistogramDataPoint.decode(&reader, allocator) catch null;
}

const DataSet = struct {
    data: benchmark_data.BenchmarkData,
    encoded: []u8,
};

fn loadFixedDataset(allocator: std.mem.Allocator) !?DataSet {
    // Try to open the test.data file
    std.debug.print("Loading dataset from {s}...\n", .{DATASET_FILENAME});

    const file = try std.fs.cwd().openFile(DATASET_FILENAME, .{});
    defer file.close();

    // Get file size and allocate buffer
    const size = (try file.stat()).size;
    std.debug.print("Dataset file size: {d} bytes\n", .{size});

    const buffer = try allocator.alloc(u8, size);

    _ = try file.readAll(buffer); // Read the entire file into the buffer
    std.debug.print("Read file contents\n", .{});

    var reader: std.Io.Reader = .fixed(buffer);

    const data = try benchmark_data.BenchmarkData.decode(&reader, allocator);

    if (data.histogram_points.items.len == 0) {
        std.debug.print("Dataset contains no histogram points\n", .{});
        return null;
    }

    std.debug.print("Loaded dataset with {d} histogram points\n", .{data.histogram_points.items.len});
    // Use the first histogram point from the dataset
    return DataSet{
        .data = data,
        .encoded = buffer,
    };
}

var input_to_encode: benchmark_data.BenchmarkData = undefined;
var input_to_decode: []u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Try to load dataset from file
    if (try loadFixedDataset(arena_allocator)) |fixed_data| {
        // Use the loaded dataset
        input_to_encode = fixed_data.data;
        input_to_decode = fixed_data.encoded;
        std.debug.print("Using fixed dataset for benchmarking\n", .{});
    } else {
        std.debug.print("Could not load dataset from file. failure\n", .{});
        return;
    }

    var bench = zbench.Benchmark.init(arena_allocator, .{});
    defer bench.deinit();

    try bench.add("encoding benchmark", bench_encode, .{});
    try bench.add("decoding benchmark", bench_decode, .{});

    var buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const writer = &stderr.interface;
    try bench.run(writer);
    try writer.flush();
}
