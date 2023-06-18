const std = @import("std");
const testing = std.testing;

test {
    _ = @import("./oneof.zig");
    _ = @import("./mapbox.zig");
    _ = @import("./graphics.zig");
}

// test "unittest.proto parse and re-encode" {
//     const binary_file =
//         "\x08\x65\x10\x66\x18\x67\x20\x68\x28\xd2\x01\x30\xd4\x01\x3d\x6b\x00\x00\x00\x41\x6c\x00" ++
//         "\x00\x00\x00\x00\x00\x00\x4d\x6d\x00\x00\x00\x51\x6e\x00\x00\x00\x00\x00\x00\x00\x5d\x00" ++
//         "\x00\xde\x42\x61\x00\x00\x00\x00\x00\x00\x5c\x40\x68\x01\x72\x03\x31\x31\x35\x7a\x03\x31" ++
//         "\x31\x36\x83\x01\x88\x01\x75\x84\x01";

//     // first decode the binary
//     const decoded = try unittest.TestAllTypes.decode(binary_file, testing.allocator);
//     defer decoded.deinit();

//     try testing.expectEqual(decoded.optional_int32, 101);
//     try testing.expectEqual(decoded.optional_int64, 102);
//     try testing.expectEqual(decoded.optional_uint32, 103);
//     try testing.expectEqual(decoded.optional_uint64, 104);
//     // TODO: try testing.expectEqual(decoded.optional_sint32, -53);
//     try testing.expectEqual(decoded.optional_sint64, 106);
//     try testing.expectEqual(decoded.optional_fixed32, 107);
//     try testing.expectEqual(decoded.optional_fixed64, @as(i64, 108));
//     try testing.expectEqual(decoded.optional_sfixed32, 109);
//     try testing.expectEqual(decoded.optional_sfixed64, @as(i64, 110));
//     try testing.expectEqual(decoded.optional_float, 111.0);
//     try testing.expectEqual(decoded.optional_double, 112.0);
//     try testing.expectEqual(decoded.optional_bool, true);
//     try testing.expectEqualSlices(u8, decoded.optional_string.?, "115");
//     try testing.expectEqualSlices(u8, decoded.optional_bytes.?, "116");

//     // then encode it
//     const encoded = try decoded.encode(testing.allocator);
//     defer testing.allocator.free(encoded);

//     // then re-decode it
//     const decoded2 = try unittest.TestAllTypes.decode(encoded, testing.allocator);
//     defer decoded2.deinit();

//     // finally assert
//     try testing.expectEqualDeep(decoded, decoded2);
// }

// test "unittest.proto parse zigzag" {
//     // first decode the binary
//     var demo = unittest.TestAllTypes.init(testing.allocator);
//     defer demo.deinit();
//     demo.optional_sint32 = -53;

//     const binary_file = "\x28\xd2\x01";
//     const gen = try demo.encode(testing.allocator);
//     defer testing.allocator.free(gen);

//     try testing.expectEqualSlices(u8, binary_file, gen);

//     // first decode the binary
//     const decoded = try unittest.TestAllTypes.decode(binary_file, testing.allocator);
//     defer decoded.deinit();

//     try testing.expectEqual(decoded.optional_sint32, -53);

//     // then encode it
//     const encoded = try decoded.encode(testing.allocator);
//     defer testing.allocator.free(encoded);

//     // then re-decode it
//     const decoded2 = try unittest.TestAllTypes.decode(encoded, testing.allocator);
//     defer decoded2.deinit();

//     // finally assert
//     try testing.expectEqualDeep(decoded, decoded2);
// }
