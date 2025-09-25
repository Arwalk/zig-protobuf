const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const vector_tile = @import("./generated/vector_tile.pb.zig");
const binary_file = @embedFile("./fixtures/vector_tile.bin");

test "mapbox decoding and re-encoding" {
    // we will decode a releaseable copy of the binary file. to ensure that string slices are not
    // leaked into final string values
    const copied_slice = try testing.allocator.dupe(u8, binary_file);

    // first decode the binary
    var reader: std.io.Reader = .fixed(copied_slice);
    var decoded = try vector_tile.Tile.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    // then encode it
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try decoded.encode(&w.writer);

    // at this moment, the copied slice will be deallocated, if strings were not copied, the decoded2 value
    // should differ
    testing.allocator.free(copied_slice);

    // then re-decode it
    var reader2: std.io.Reader = .fixed(w.written());
    var decoded2 = try vector_tile.Tile.decode(&reader2, testing.allocator);
    defer decoded2.deinit(std.testing.allocator);

    // finally assert
    try testing.expectEqualDeep(decoded, decoded2);
    var w2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w2.deinit();
    try decoded2.encode(&w2.writer);

    try testing.expectEqualSlices(u8, w.written(), w2.written());
}
