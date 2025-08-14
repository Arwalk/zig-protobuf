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
    const decoded = try vector_tile.Tile.decode(copied_slice, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    // then encode it
    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    const w = encoded.writer(std.testing.allocator);

    try decoded.encode(w.any(), testing.allocator);

    // at this moment, the copied slice will be deallocated, if strings were not copied, the decoded2 value
    // should differ
    testing.allocator.free(copied_slice);

    // then re-decode it
    const decoded2 = try vector_tile.Tile.decode(encoded.items, testing.allocator);
    defer decoded2.deinit(std.testing.allocator);

    // finally assert
    try testing.expectEqualDeep(decoded, decoded2);

    var encoded2: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded2.deinit(std.testing.allocator);
    const w2 = encoded2.writer(std.testing.allocator);

    try decoded2.encode(w2.any(), testing.allocator);

    try testing.expectEqualSlices(u8, encoded.items, encoded2.items);
}
