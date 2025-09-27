const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const graphics = @import("./generated/graphics.pb.zig");
const binary_file = @embedFile("./fixtures/graphics.bin");

test "GraphicsDB" {
    // first decode the binary
    var reader: std.Io.Reader = .fixed(binary_file);
    var decoded: graphics.GraphicsDB = try graphics.GraphicsDB.decode(
        &reader,
        testing.allocator,
    );

    // then encode it
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try decoded.encode(&w.writer, std.testing.allocator);

    // dupe the decoded
    var decoded_dupe = try decoded.dupe(testing.allocator);
    defer decoded_dupe.deinit(std.testing.allocator);

    {
        // encode and assert equality
        var w_dupe: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w_dupe.deinit();
        try decoded_dupe.encode(&w_dupe.writer, std.testing.allocator);

        try testing.expectEqualSlices(u8, w_dupe.written(), w.written());
    }

    // then re-decode it
    var reader2: std.Io.Reader = .fixed(w.written());
    var decoded2: graphics.GraphicsDB = try graphics.GraphicsDB.decode(
        &reader2,
        testing.allocator,
    );
    defer decoded2.deinit(std.testing.allocator);

    // finally assert equal objects
    try testing.expectEqualDeep(decoded, decoded2);

    // then clean up the decoded memory of the first object. this should free all string slices
    decoded.deinit(std.testing.allocator);

    {
        // encode and assert equality again
        var w_dupe: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w_dupe.deinit();
        try decoded_dupe.encode(&w_dupe.writer, std.testing.allocator);

        try testing.expectEqualSlices(u8, w.written(), w_dupe.written());
    }

    // and equal encodings
    var w2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w2.deinit();
    try decoded2.encode(&w2.writer, std.testing.allocator);

    try testing.expectEqualSlices(u8, w.written(), w2.written());

    // var file = try std.fs.cwd().openFile("debug/graphics-out.bin", .{ .mode = .write_only });
    // defer file.close();

    // _ = try file.write(encoded);
}
