const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const graphics = @import("./generated/graphics.pb.zig");
const binary_file = @embedFile("./fixtures/graphics.bin");

test "GraphicsDB" {
    // first decode the binary
    const decoded = try graphics.GraphicsDB.decode(binary_file, testing.allocator);

    // then encode it
    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    const w = encoded.writer(std.testing.allocator);
    try decoded.encode(w.any(), std.testing.allocator);

    // dupe the decoded
    const decoded_dupe = try decoded.dupe(testing.allocator);
    defer decoded_dupe.deinit();

    {
        // encode and assert equality
        var encoded_dupe: std.ArrayListUnmanaged(u8) = .empty;
        defer encoded_dupe.deinit(std.testing.allocator);
        const w_dupe = encoded_dupe.writer(std.testing.allocator);
        try decoded_dupe.encode(w_dupe.any(), std.testing.allocator);

        try testing.expectEqualSlices(u8, encoded.items, encoded_dupe.items);
    }

    // then re-decode it
    const decoded2 = try graphics.GraphicsDB.decode(encoded.items, testing.allocator);
    defer decoded2.deinit();

    // finally assert equal objects
    try testing.expectEqualDeep(decoded, decoded2);

    // then clean up the decoded memory of the first object. this should free all string slices
    decoded.deinit();

    {
        // encode and assert equality again
        var encoded_dupe: std.ArrayListUnmanaged(u8) = .empty;
        defer encoded_dupe.deinit(std.testing.allocator);
        const w_dupe = encoded_dupe.writer(std.testing.allocator);
        try decoded_dupe.encode(w_dupe.any(), std.testing.allocator);

        try testing.expectEqualSlices(u8, encoded.items, encoded_dupe.items);
    }

    // and equal encodings
    var encoded2: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded2.deinit(std.testing.allocator);
    const w2 = encoded2.writer(std.testing.allocator);
    try decoded2.encode(w2.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, encoded.items, encoded2.items);

    // var file = try std.fs.cwd().openFile("debug/graphics-out.bin", .{ .mode = .write_only });
    // defer file.close();

    // _ = try file.write(encoded);
}
