//! Protocol Buffers definitions and functions for wire encoding/decoding.
const std = @import("std");

const protobuf = @import("protobuf.zig");

/// Wire type.
pub const Type = enum(u3) {
    /// int32, int64, uint32, uint64, sint32, sint64, bool, enum
    varint = 0,
    /// fixed64, sfixed64, double - referred to as `i64` in protobuf docs
    fixed64 = 1,
    /// string, bytes, embedded messages, packed repeated fields
    len = 2,
    /// group start (deprecated)
    sgroup = 3,
    /// group end (deprecated)
    egroup = 4,
    /// fixed32, sfixed32, float - referred to as `i32` in protobuf docs
    fixed32 = 5,
};

/// Record tag.
pub const Tag = packed struct(u32) {
    /// Wire type.
    wire_type: Type,
    /// Field number.
    field: u29,

    /// Encode tag to byte stream. Returns number of bytes used for encoding,
    /// which is guaranteed to be between 1-5 inclusive.
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
        const tag: Tag = .{ .wire_type = .len, .field = 15 };

        var result: [2]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&result);
        const writer = fbs.writer();

        const encoded = try tag.encode(writer.any());

        try std.testing.expectEqual(1, encoded);
        try std.testing.expectEqual((15 << 3) | 2, result[0]);

        fbs.reset();
        const tag2: Tag = .{ .wire_type = .fixed64, .field = 1 };
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

        try std.testing.expectEqual(.fixed32, tag.wire_type);
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

    pub fn decode(raw_int: anytype) @TypeOf(raw_int) {
        const RawInt = @TypeOf(raw_int);
        comptime std.debug.assert(RawInt == i32 or RawInt == i64);

        const unsigned: if (RawInt == i32) u32 else u64 = @bitCast(raw_int);

        if (raw_int & 0x1 == 0) return @bitCast(unsigned >> 1);
        return @bitCast(
            (unsigned >> 1) ^ (comptime ~@as(@TypeOf(unsigned), 0)),
        );
    }

    test decode {
        try std.testing.expectEqual(0, ZigZag.decode(@as(i32, 0)));
        try std.testing.expectEqual(-1, ZigZag.decode(@as(i32, 1)));
        try std.testing.expectEqual(1, ZigZag.decode(@as(i32, 2)));
        try std.testing.expectEqual(
            std.math.maxInt(i32),
            ZigZag.decode(@as(i32, @bitCast(@as(u32, 0xfffffffe)))),
        );
        try std.testing.expectEqual(
            std.math.minInt(i32),
            ZigZag.decode(@as(i32, @bitCast(@as(u32, 0xffffffff)))),
        );
        try std.testing.expectEqual(-2, ZigZag.decode(@as(i32, 3)));
        try std.testing.expectEqual(-500, ZigZag.decode(@as(i32, 999)));

        try std.testing.expectEqual(0, ZigZag.decode(@as(i64, 0)));
        try std.testing.expectEqual(-1, ZigZag.decode(@as(i64, 1)));
        try std.testing.expectEqual(1, ZigZag.decode(@as(i64, 2)));
        try std.testing.expectEqual(
            std.math.maxInt(i64),
            ZigZag.decode(@as(i64, @bitCast(@as(u64, 0xfffffffffffffffe)))),
        );
        try std.testing.expectEqual(
            std.math.minInt(i64),
            ZigZag.decode(@as(i64, @bitCast(@as(u64, 0xffffffffffffffff)))),
        );
        try std.testing.expectEqual(-500, ZigZag.decode(@as(i64, 999)));
    }
};

/// Decode a non-slice scalar type from reader. Slice scalar types should be
/// decoded by directly reading a slice from the reader.
pub fn decodeScalar(
    comptime scalar: protobuf.FieldType.Scalar,
    reader: std.io.AnyReader,
) (std.io.AnyReader.Error || protobuf.DecodingError)!scalar.toType() {
    comptime std.debug.assert(!scalar.isSlice());

    if (comptime scalar.isVariable()) {
        const Result = if (comptime scalar == .int32)
            i64
        else
            comptime scalar.toType();

        var val: Result = 0;
        const max_bytes: comptime_int = comptime b: {
            var byte_count: usize = 0;
            while (7 * byte_count < @bitSizeOf(Result)) {
                byte_count += 1;
            }

            // Valid negative values for `int32`, e.g. -1, may be sent in the
            // `int64` equivalent encoding.
            if (scalar == .int32) byte_count = 10;
            break :b byte_count;
        };
        for (0..max_bytes) |i| {
            const b = try reader.readByte();
            const num = b & 0x7F;
            val |= @as(Result, num) << @intCast(7 * i);
            if (b >> 7 == 0) break;
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        }

        // As `int32` may receive `int64` equivalent encoding values, ensure
        // that values actually fit within `int32` range.
        if (comptime scalar == .int32) {
            // Encoded as `int32`
            if (val & @as(i64, @bitCast(@as(u64, 0xFFFFFFFF00000000))) == 0) {
                return @truncate(val);
            }

            if (val < std.math.minInt(i32) or val > std.math.maxInt(i32)) {
                @branchHint(.cold);
                return error.InvalidInput;
            }

            return @intCast(val);
        }

        if (comptime scalar.isZigZag()) {
            val = ZigZag.decode(val);
        }

        return val;
    }

    if (comptime scalar.isFixed()) {
        const Unsigned = if (@bitSizeOf(scalar.toType()) == 32)
            u32
        else
            u64;

        var val: Unsigned = 0;
        for (0..@sizeOf(Unsigned)) |i| {
            const b = try reader.readByte();
            val |= @as(Unsigned, b) << @intCast(8 * i);
        }
        return @bitCast(val);
    }

    if (comptime scalar == .bool) {
        const b = try reader.readByte();
        if (b == 0) {
            return false;
        } else if (b == 1) {
            return true;
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        }
    }
}

test decodeScalar {
    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const decoded: u32 = try decodeScalar(.uint32, r.any());

        try std.testing.expectEqual(std.math.maxInt(u32), decoded);
    }

    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const decoded: i32 = try decodeScalar(.sint32, r.any());

        try std.testing.expectEqual(std.math.minInt(i32), decoded);
    }

    { // Oversized `int32` value
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x7F,
        };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const max_u64 = decodeScalar(.int32, r.any());
        try std.testing.expectError(error.InvalidInput, max_u64);
    }

    { // Barely oversized `int32` value
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const barely_too_big = decodeScalar(.int32, r.any());
        try std.testing.expectError(error.InvalidInput, barely_too_big);
    }

    { // Valid `int32` encoded as `int64`
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x01,
        };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const decoded = try decodeScalar(.int32, r.any());
        try std.testing.expectEqual(-1, decoded);
    }

    { // Valid `int32` encoded as `int32`
        const bytes: []const u8 = &.{
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0x0F,
        };
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const decoded = try decodeScalar(.int32, r.any());
        try std.testing.expectEqual(-1, decoded);
    }
}

test {
    _ = Tag;
    _ = ZigZag;
}
