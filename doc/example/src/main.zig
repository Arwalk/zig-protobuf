const std = @import("std");
const example = @import("proto/example.pb.zig");

// A `Project` message, in hexadecimal.
const encoded_project = "0a180a0e70726f6a6563745f617574686f721206417277616c6b" ++
    "0a1c0a0c70726f6a6563745f6e616d65120c7a69672d70726f746f627566" ++
    "0a170a1070726f6a6563745f6c616e677561676512035a6967";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var input_buffer: [encoded_project.len / 2]u8 = undefined;
    const input = try std.fmt.hexToBytes(&input_buffer, encoded_project);

    // Decode the message. This reader is for bytes, any other `std.Io.Reader` works too.
    var reader: std.Io.Reader = .fixed(input);
    var project: example.Project = try .decode(&reader, allocator);
    defer project.deinit(allocator);

    for (project.data.items) |entry| {
        try stdout.print("{s}: {s}\n", .{ entry.key, entry.value });
    }

    // Encode it back. This writer is for memory, any other `std.Io.Writer` works too.
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try project.encode(&output.writer, allocator);

    try stdout.print("{x}\n", .{output.written()});

    try stdout.flush();
}
