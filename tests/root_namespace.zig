const std = @import("std");
const protobuf = @import("./generated/protobuf.pb.zig");
const root_import = @import("./generated/RootImport.pb.zig");

test "root namespace message" {
    var foo: protobuf.RootNamespaceMessage = .{};
    defer foo.deinit(std.testing.allocator);

    foo.other = .{ .field1 = 3, .field2 = .OPT1 };
    foo.bar = .BAZ;

    var foo_import: root_import.RootNamespaceImporter = .{};
    defer foo_import.deinit(std.testing.allocator);

    foo_import.enum_field = .OPT1;

    try std.testing.expectEqual(foo.other.?.field2, foo_import.enum_field);
}
