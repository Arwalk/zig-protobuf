//! Protocol Buffers definitions and functions for wire encoding/decoding.
const std = @import("std");

const protobuf = @import("protobuf.zig");

/// Wire type.
pub const Type = enum(u3) {
    /// int32, int64, uint32, uint64, sint32, sint64, bool, enum
    varint = 0,
    /// fixed64, sfixed64, double
    i64 = 1,
    /// string, bytes, embedded messages, packed repeated fields
    len = 2,
    /// group start (deprecated)
    sgroup = 3,
    /// group end (deprecated)
    egroup = 4,
    /// fixed32, sfixed32, float
    i32 = 5,
};

/// Record tag.
pub const Tag = packed struct(u32) {
    /// Wire type.
    type: Type,
    /// Field number.
    field: u29,

    /// Encode tag to byte stream. Returns number of bytes used for encoding,
    /// which is guaranteed to be between 1-3 inclusive.
    pub inline fn encode(
        comptime self: Tag,
        writer: std.io.AnyWriter,
    ) !usize {
        const out_bytes: []const u8 = comptime b: {
            var raw: u32 = @bitCast(self);
            var buf: [5]u8 = undefined;
            const len: u3 = for (0..5) |i| {
                if (raw < 0x80) {
                    buf[i] = @intCast(raw);
                    break i + 1;
                } else {
                    buf[i] = 0x80 | @as(u8, @intCast(raw & 0x7F));
                }
                raw >>= 7;
            } else unreachable;

            break :b std.fmt.comptimePrint("{s}", .{buf[0..len]});
        };
        try writer.writeAll(out_bytes);
        return out_bytes.len;
    }

    test encode {
        const tag: Tag = .{ .type = .len, .field = 15 };

        var result: [2]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&result);
        const writer = fbs.writer();

        const encoded = try tag.encode(writer.any());

        try std.testing.expectEqual(1, encoded);
        try std.testing.expectEqual((15 << 3) | 2, result[0]);

        fbs.reset();
        const tag2: Tag = .{ .type = .i64, .field = 1 };
        const encoded2 = try tag2.encode(writer.any());
        try std.testing.expectEqual(1, encoded2);
        try std.testing.expectEqual((1 << 3) | 1, result[0]);
    }

    /// Decode from byte stream to tag. Unlike normal `varint` types, the
    /// encoding for a tag is guaranteed not to use ZigZag encoding, as the
    /// tag will always be unsigned.
    pub fn decode(reader: std.io.AnyReader) !Tag {
        var raw_result: u32 = 0;

        // Guaranteed that a tag will take less than 5 bytes in stream. Any
        // more bytes will result in an invalid field number (exceeding proto
        // limits), and as such should be considered an invalid tag.
        for (0..4) |i| {
            const b = try reader.readByte();
            const num = b & 0x7F;
            raw_result |= @as(u32, num) << @intCast(7 * i);
            if (b >> 7 == 0) break;
        } else {
            const b = try reader.readByte();
            if (b & 0xF0 > 0) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            raw_result |= @as(u32, b) << @intCast(7 * 4);
        }

        const invalid_wire_type = (raw_result & 0x7) > 5;
        if (invalid_wire_type) {
            @branchHint(.cold);
            return error.InvalidTag;
        }

        return @bitCast(@as(u32, @intCast(raw_result)));
    }

    test decode {
        const bytes: []const u8 = &.{ 0xFD, 0xFF, 0xFF, 0xFF, 0x0F };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();
        const tag: Tag = try decode(r.any());

        try std.testing.expectEqual(.i32, tag.type);
        try std.testing.expectEqual(0x1FFFFFFF, tag.field);
    }
};

pub const ZigZag = struct {
    pub fn encode(int_value: anytype) u64 {
        const type_of_val = @TypeOf(int_value);
        const to_int64: i64 = switch (type_of_val) {
            i32 => @intCast(int_value),
            i64 => int_value,
            else => @compileError("should not be here"),
        };
        const calc = (to_int64 << 1) ^ (to_int64 >> 63);
        return @bitCast(calc);
    }

    test encode {
        try std.testing.expectEqual(@as(u64, 0), ZigZag.encode(@as(i32, 0)));
        try std.testing.expectEqual(@as(u64, 1), ZigZag.encode(@as(i32, -1)));
        try std.testing.expectEqual(@as(u64, 2), ZigZag.encode(@as(i32, 1)));
        try std.testing.expectEqual(
            @as(u64, 0xfffffffe),
            ZigZag.encode(@as(i32, std.math.maxInt(i32))),
        );
        try std.testing.expectEqual(
            @as(u64, 0xffffffff),
            ZigZag.encode(@as(i32, std.math.minInt(i32))),
        );

        try std.testing.expectEqual(@as(u64, 0), ZigZag.encode(@as(i64, 0)));
        try std.testing.expectEqual(@as(u64, 1), ZigZag.encode(@as(i64, -1)));
        try std.testing.expectEqual(@as(u64, 2), ZigZag.encode(@as(i64, 1)));
        try std.testing.expectEqual(
            @as(u64, 0xfffffffffffffffe),
            ZigZag.encode(@as(i64, std.math.maxInt(i64))),
        );
        try std.testing.expectEqual(
            @as(u64, 0xffffffffffffffff),
            ZigZag.encode(@as(i64, std.math.minInt(i64))),
        );
    }

    pub fn decode(comptime T: type, zig_zag_int: u64) !T {
        comptime {
            switch (T) {
                i32, i64 => {},
                else => @compileError("should only pass i32 or i64 here"),
            }
        }

        const v: T = block: {
            var v = zig_zag_int >> 1;
            if (zig_zag_int & 0x1 != 0) {
                v = v ^ (~@as(u64, 0));
            }

            const bitcasted: i64 = @as(i64, @bitCast(v));

            break :block std.math.cast(T, bitcasted) orelse return error.InvalidInput;
        };

        return v;
    }

    test decode {
        try std.testing.expectEqual(@as(i32, 0), ZigZag.decode(i32, 0));
        try std.testing.expectEqual(@as(i32, -1), ZigZag.decode(i32, 1));
        try std.testing.expectEqual(@as(i32, 1), ZigZag.decode(i32, 2));
        try std.testing.expectEqual(
            @as(i32, std.math.maxInt(i32)),
            ZigZag.decode(i32, 0xfffffffe),
        );
        try std.testing.expectEqual(
            @as(i32, std.math.minInt(i32)),
            ZigZag.decode(i32, 0xffffffff),
        );

        try std.testing.expectEqual(@as(i64, 0), ZigZag.decode(i64, 0));
        try std.testing.expectEqual(@as(i64, -1), ZigZag.decode(i64, 1));
        try std.testing.expectEqual(@as(i64, 1), ZigZag.decode(i64, 2));
        try std.testing.expectEqual(
            @as(i64, std.math.maxInt(i64)),
            ZigZag.decode(i64, 0xfffffffffffffffe),
        );
        try std.testing.expectEqual(
            @as(i64, std.math.minInt(i64)),
            ZigZag.decode(i64, 0xffffffffffffffff),
        );
    }
};

test {
    _ = Tag;
    _ = ZigZag;
}
