//! Protocol Buffers definitions and functions for wire encoding/decoding.
const std = @import("std");

const protobuf = @import("protobuf.zig");
const extension = @import("extension.zig");
const ExtensionRegistry = extension.ExtensionRegistry;
const builtin = @import("builtin");
const log = if (builtin.os.tag != .freestanding) std.log.scoped(.zig_protobuf) else struct {
    // no-op log implementation for freestanding targets
    pub fn debug(
        comptime _: []const u8,
        _: anytype,
    ) void {}
};

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
        writer: *std.Io.Writer,
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
        var writer: std.Io.Writer = .fixed(&result);

        const encoded = try tag.encode(&writer);

        try std.testing.expectEqual(1, encoded);
        try std.testing.expectEqual((15 << 3) | 2, result[0]);

        writer = .fixed(&result);
        const tag2: Tag = .{ .wire_type = .fixed64, .field = 1 };
        const encoded2 = try tag2.encode(&writer);
        try std.testing.expectEqual(1, encoded2);
        try std.testing.expectEqual((1 << 3) | 1, result[0]);
    }

    /// Decode from byte stream to tag. Unlike normal `varint` types, the
    /// encoding for a tag is guaranteed not to use ZigZag encoding, as the
    /// tag will always be unsigned.
    pub fn decode(reader: *std.Io.Reader) !struct {
        /// Decoded tag.
        Tag,
        /// Number of bytes consumed from reader.
        usize,
    } {
        // Unlike uint32 values, tags may not be truncated: a tag is at most 5
        // bytes long and its value must fit in 32 bits.
        var raw_result: u32 = 0;
        const consumed: usize = for (0..5) |i| {
            const b = try reader.takeByte();
            if (i == 4 and b > 0x0F) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            raw_result |= @as(u32, b & 0x7F) << @intCast(7 * i);
            if (b & 0x80 == 0) break i + 1;
        } else unreachable; // the 5th byte never has its continuation bit set

        const invalid_wire_type = (raw_result & 0x7) > 5;
        if (invalid_wire_type) {
            @branchHint(.cold);
            return error.InvalidInput;
        }

        // Field number 0 is reserved/invalid in proto3.
        if (raw_result >> 3 == 0) {
            @branchHint(.cold);
            return error.InvalidInput;
        }

        return .{ @bitCast(raw_result), consumed };
    }

    test decode {
        const bytes: []const u8 = &.{ 0xFD, 0xFF, 0xFF, 0xFF, 0x0F };
        var reader: std.Io.Reader = .fixed(bytes);
        const tag: Tag, const consumed = try decode(&reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(.fixed32, tag.wire_type);
        try std.testing.expectEqual(0x1FFFFFFF, tag.field);

        // Values above UINT32_MAX and tags longer than 5 bytes are invalid.
        const invalid: []const []const u8 = &.{
            &.{ 0x80, 0x80, 0x80, 0x80, 0x40 },
            &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x0F },
            &.{ 0x88, 0x80, 0x80, 0x80, 0x80, 0x00 },
        };
        for (invalid) |input| {
            var r: std.Io.Reader = .fixed(input);
            try std.testing.expectError(error.InvalidInput, decode(&r));
        }
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

/// Decode an enum value from a raw integer. For non-exhaustive enums (proto3 style,
/// with `_`), any integer value is valid. For exhaustive enums, only declared values
/// are accepted.
inline fn enumFromRaw(comptime E: type, raw: i32) ?E {
    if (comptime !@typeInfo(E).@"enum".is_exhaustive) {
        return @enumFromInt(raw);
    }
    return std.enums.fromInt(E, raw);
}

/// Decode a non-slice scalar type from reader. Slice scalar types should be
/// decoded by directly reading a slice from the reader.
pub fn decodeScalar(
    comptime scalar: protobuf.FieldType.Scalar,
    reader: *std.Io.Reader,
) (std.Io.Reader.Error || protobuf.DecodingError)!struct {
    /// Resulting decoded scalar.
    scalar.toType(),
    /// Number of bytes consumed from reader.
    usize,
} {
    comptime std.debug.assert(!scalar.isSlice());

    if (comptime scalar.isVariable()) {
        // int32 uses i64 to handle negative values sign-extended to 64 bits.
        // uint32 uses u64 to handle over-long encodings; truncated to 32 bits.
        const Result = if (comptime scalar == .int32)
            i64
        else if (comptime scalar == .uint32)
            u64
        else
            comptime scalar.toType();

        var val: Result = 0;
        const max_bytes: comptime_int = comptime b: {
            var byte_count: usize = 0;
            while (7 * byte_count < @bitSizeOf(Result)) {
                byte_count += 1;
            }

            // int32/uint32 may be encoded with int64 sizing (up to 10 bytes).
            if (scalar == .int32 or scalar == .uint32) byte_count = 10;
            break :b byte_count;
        };
        const consumed = for (0..max_bytes) |i| {
            const b = try reader.takeByte();
            const num = b & 0x7F;
            val |= @as(Result, num) << @intCast(7 * i);
            if (b >> 7 == 0) break i + 1;
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        };

        // Proto3 spec: int32/uint32 may be encoded with int64 sizing.
        // Out-of-range values are truncated to 32 bits.
        if (comptime scalar == .int32) {
            return .{ @truncate(val), consumed };
        }
        if (comptime scalar == .uint32) {
            return .{ @truncate(val), consumed };
        }

        if (comptime scalar.isZigZag()) {
            val = ZigZag.decode(val);
        }

        return .{ val, consumed };
    }

    if (comptime scalar.isFixed()) {
        const Unsigned = if (@bitSizeOf(scalar.toType()) == 32)
            u32
        else
            u64;

        var val: Unsigned = 0;
        for (0..@sizeOf(Unsigned)) |i| {
            const b = try reader.takeByte();
            val |= @as(Unsigned, b) << @intCast(8 * i);
        }
        return .{ @bitCast(val), @sizeOf(Unsigned) };
    }

    if (comptime scalar == .bool) {
        // Proto3: any non-zero varint value is true; multi-byte encodings are accepted.
        var val: u64 = 0;
        const consumed = for (0..10) |i| {
            const b = try reader.takeByte();
            val |= @as(u64, b & 0x7F) << @intCast(7 * i);
            if (b >> 7 == 0) break i + 1;
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        };
        return .{ val != 0, consumed };
    }
}

test decodeScalar {
    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };

        var reader: std.Io.Reader = .fixed(bytes);
        const decoded: u32, const consumed = try decodeScalar(.uint32, &reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(std.math.maxInt(u32), decoded);
    }

    {
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.sint32, &reader);

        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(std.math.minInt(i32), decoded);
    }

    { // int32 with 9-byte encoding (truncated to i32)
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
        var reader: std.Io.Reader = .fixed(bytes);

        const result: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(9, consumed);
        try std.testing.expectEqual(-1, result); // lower 32 bits of i64_max
    }

    { // int32 with 5-byte encoding exceeding 32-bit range (truncated)
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 };
        var reader: std.Io.Reader = .fixed(bytes);

        const result: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(268435455, result); // lower 32 bits
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
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(10, consumed);
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
        var reader: std.Io.Reader = .fixed(bytes);

        const decoded: i32, const consumed = try decodeScalar(.int32, &reader);
        try std.testing.expectEqual(5, consumed);
        try std.testing.expectEqual(-1, decoded);
    }
}

/// Decode a repeated field from reader. Return number of consumed bytes.
pub fn decodeRepeated(
    result: anytype,
    allocator: std.mem.Allocator,
    comptime field: protobuf.FieldType.Repeated,
    reader: *std.Io.Reader,
    options: struct {
        /// Number of bytes to parse. Provided for length-delimited records
        /// or packed repeated fields.
        bytes: ?usize = null,
        /// Field number of a delimited (group-encoded) submessage element,
        /// whose end is marked by the matching EGROUP tag.
        group: ?u32 = null,
        /// Reject strings that are not valid UTF-8.
        verify_utf8: bool = false,
        /// Where closed-enum values that do not match any enumerator are
        /// stored, as unknown varint fields numbered `field_number`. They are
        /// dropped when null.
        unknown_fields: ?*std.ArrayList(u8) = null,
        field_number: u29 = 0,
        /// Known extensions, validated in decoded submessages.
        extensions: ?*const ExtensionRegistry = null,
    },
) (std.Io.Reader.Error || std.mem.Allocator.Error || protobuf.DecodingError)!usize {
    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const ResultList = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const Result = comptime @typeInfo(
        @FieldType(ResultList, "items"),
    ).pointer.child;
    comptime std.debug.assert(ResultList == std.ArrayList(Result));

    const current_items = result.items.len;
    errdefer result.shrinkRetainingCapacity(current_items);

    switch (comptime field) {
        .scalar => |scalar| {
            if (comptime scalar.isSlice()) {
                // string/bytes are length-delimited, and cannot be packed.
                std.debug.assert(options.bytes != null);

                const bytes = try reader.readAlloc(allocator, options.bytes.?);
                errdefer allocator.free(bytes);
                if (options.verify_utf8 and !std.unicode.utf8ValidateSlice(bytes)) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }

                try result.append(allocator, bytes);
                return bytes.len;
            }
            // Packed repeated scalar.
            else if (options.bytes) |bytes| {
                var consumed: usize = 0;
                while (consumed < bytes) {
                    const decoded, const c = try decodeScalar(scalar, reader);
                    try result.append(allocator, decoded);
                    consumed += c;
                }
                if (consumed != bytes) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return bytes;
            }
            // Unpacked repeated scalar.
            else {
                const decoded, const consumed =
                    try decodeScalar(scalar, reader);
                try result.append(allocator, decoded);
                return consumed;
            }
        },
        .@"enum" => {
            // Packed repeated enum.
            if (options.bytes) |bytes| {
                var consumed: usize = 0;
                while (consumed < bytes) {
                    const raw, const c = try decodeScalar(.int32, reader);
                    consumed += c;
                    if (enumFromRaw(Result, raw)) |decoded| {
                        try result.append(allocator, decoded);
                    } else if (options.unknown_fields) |unknown| {
                        try appendUnknownVarint(allocator, unknown, options.field_number, raw);
                    }
                }
                if (consumed > bytes) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
                return consumed;
            }
            // Unpacked repeated enum.
            else {
                const raw, const consumed = try decodeScalar(.int32, reader);
                if (enumFromRaw(Result, raw)) |decoded| {
                    try result.append(allocator, decoded);
                } else if (options.unknown_fields) |unknown| {
                    try appendUnknownVarint(allocator, unknown, options.field_number, raw);
                }
                return consumed;
            }
        },
        .submessage => {
            // Submessages are length-prefixed or delimited, and cannot be packed.
            std.debug.assert(options.bytes != null or options.group != null);

            try result.append(
                allocator,
                try protobuf.init(Result, allocator),
            );
            errdefer result.items[result.items.len - 1].deinit(allocator);
            const msg = &result.items[result.items.len - 1];
            const consumed = try decodeMessage(
                msg,
                allocator,
                reader,
                .{ .bytes = options.bytes, .group = options.group, .extensions = options.extensions },
            );
            if (options.bytes) |bytes| if (consumed > bytes) {
                @branchHint(.cold);
                return error.InvalidInput;
            };
            return consumed;
        },
    }
}

test decodeRepeated {
    // length delimited message including a list of varints
    {
        const bytes: []const u8 = &.{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(std.testing.allocator);

        var reader: std.Io.Reader = .fixed(bytes);

        const consumed = try decodeRepeated(
            &list,
            std.testing.allocator,
            .{ .scalar = .uint32 },
            &reader,
            .{
                .bytes = bytes.len,
            },
        );
        try std.testing.expectEqual(bytes.len, consumed);
        try std.testing.expectEqualSlices(
            u32,
            &.{ 3, 270, 86942 },
            list.items,
        );
    }

    // Pre-allocated capacity (capacity=8, items=0) + malformed packed field:Expand comment
    // two 2-byte varints (4 bytes consumed) against options.bytes=3 triggers
    // error.InvalidInput.
    {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(std.testing.allocator);

        try list.ensureTotalCapacity(std.testing.allocator, 8);
        try list.append(std.testing.allocator, 0x1337);

        // Two varints encoding 270 (0x8e 0x02 each); consumed=4 but options.bytes=3.
        const input: []const u8 = &.{ 0x8e, 0x02, 0x8e, 0x02 };
        var reader: std.Io.Reader = .fixed(input);

        try std.testing.expectError(
            error.InvalidInput,
            decodeRepeated(
                &list,
                std.testing.allocator,
                .{ .scalar = .uint32 },
                &reader,
                .{ .bytes = 3 },
            ),
        );

        // previous elements should remain unaltered
        try std.testing.expectEqual(1, list.items.len);
        try std.testing.expectEqual(0x1337, list.items[0]);

        // capacity should remain >8
        try std.testing.expect(list.capacity >= 8);
    }
}

/// Bounds of a submessage being decoded by `decodeMessage`.
pub const SubmessageOptions = struct {
    /// Number of bytes to parse. Provided for length-prefixed submessages.
    bytes: ?usize = null,
    /// Field number of a delimited (group-encoded) submessage. Decoding
    /// stops after the matching EGROUP tag, which must be present.
    group: ?u32 = null,
    /// Known extensions, validated when decoding messages they extend.
    extensions: ?*const ExtensionRegistry = null,
};

/// Stores a closed-enum value that matches none of the enumerators as an
/// unknown varint field, as the protobuf spec requires for closed enums.
fn appendUnknownVarint(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    field: u29,
    raw: i32,
) std.mem.Allocator.Error!void {
    var tag_bytes: [10]u8 = undefined;
    const tag_len = encodeTagBytes(.{ .wire_type = .varint, .field = field }, &tag_bytes);
    try buf.appendSlice(allocator, tag_bytes[0..tag_len]);
    // Negative values are sign-extended to 64 bits, as for int32 fields.
    var value: u64 = @bitCast(@as(i64, raw));
    while (value > 0x7F) : (value >>= 7) {
        try buf.append(allocator, 0x80 | @as(u8, @truncate(value)));
    }
    try buf.append(allocator, @intCast(value));
}

/// Decode a message from reader.
pub fn decodeMessage(
    result: anytype,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: SubmessageOptions,
) (std.Io.Reader.Error || std.mem.Allocator.Error || protobuf.DecodingError)!usize {
    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const Result = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const ResultField = std.meta.FieldEnum(Result);
    comptime std.debug.assert(@TypeOf(result) == *Result);
    const desc_table = Result._desc_table;

    var consumed: usize = 0;
    // Accumulate unknown fields if the struct declares _unknown_fields.
    const has_unknown_fields = comptime @hasField(Result, "_unknown_fields");
    var unknown_buf: if (has_unknown_fields) std.ArrayList(u8) else void =
        if (comptime has_unknown_fields) .empty else {};
    defer if (comptime has_unknown_fields) unknown_buf.deinit(allocator);
    // Accumulate extension fields if the struct declares extension ranges.
    const has_extensions = comptime @hasField(Result, "_extensions");
    var extension_buf: if (has_extensions) std.ArrayList(u8) else void =
        if (comptime has_extensions) .empty else {};
    defer if (comptime has_extensions) extension_buf.deinit(allocator);
    main_loop: while (true) {
        const tag: Tag, const tag_c = b: {
            // A group must be terminated by its EGROUP tag, never by EOF.
            if (options.group != null) break :b try Tag.decode(reader);
            if (options.bytes) |b| {
                if (consumed < b) {
                    break :b try Tag.decode(reader);
                } else break :main_loop;
            } else {
                break :b Tag.decode(reader) catch |e| switch (e) {
                    error.EndOfStream => break :main_loop,
                    else => return e,
                };
            }
        };
        consumed += tag_c;

        if (tag.wire_type == .egroup) {
            if (options.group) |group| {
                if (tag.field == group) break :main_loop;
            }
            // An EGROUP tag that does not close the current group is invalid.
            return error.InvalidInput;
        }

        // MessageSet: extensions are encoded as items of group 1, holding
        // their type id and message.
        if (comptime extension.isMessageSet(Result)) {
            if (tag.field == 1 and tag.wire_type == .sgroup) {
                consumed += try extension.readMessageSetItem(allocator, reader, &extension_buf);
                continue :main_loop;
            }
        }

        fields: inline for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |field| {
            const field_desc: protobuf.FieldDescriptor =
                comptime @field(desc_table, field.name);
            const field_info: std.builtin.Type.StructField =
                std.meta.fieldInfo(Result, @field(ResultField, field.name));

            if (comptime field_desc.ftype != .oneof) {
                if (comptime field_desc.field_number == null)
                    comptime continue;
                const fnum = comptime field_desc.field_number.?;
                if (fnum != tag.field) comptime continue;
                if (comptime field_desc.isDelimited()) {
                    if (tag.wire_type != .sgroup) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                } else if (comptime field_desc.ftype == .packed_repeated) {
                    // Packed repeated fields may be encoded as non-packed.
                    if (tag.wire_type != .len and
                        tag.wire_type != field_desc.ftype.packed_repeated.toWire())
                    {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                } else if (comptime field_desc.ftype == .repeated) {
                    // Non-packed repeated fields may be encoded as packed.
                    if (tag.wire_type != .len and
                        tag.wire_type != field_desc.ftype.repeated.toWire())
                    {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                } else if (tag.wire_type != comptime field_desc.ftype.toWire()) {
                    @branchHint(.cold);
                    return error.InvalidInput;
                }
            }

            const Field = comptime @FieldType(Result, field.name);
            const field_ti = comptime @typeInfo(Field);

            switch (comptime field_desc.ftype) {
                .scalar => |scalar| {
                    if (comptime scalar.isSlice()) {
                        if (tag.wire_type != .len) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }
                        std.debug.assert(tag.wire_type == .len);
                        const len, const len_c =
                            try decodeScalar(.int32, reader);
                        consumed += len_c;
                        if (len < 0) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }

                        const new: []u8 = if (len > 0)
                            try allocator.alloc(u8, @intCast(len))
                        else
                            &.{};
                        errdefer if (len > 0) allocator.free(new);

                        if (len > 0) {
                            _ = try reader.readSliceAll(new);
                            consumed += @intCast(len);
                        }
                        if (comptime field_desc.verifiesUtf8()) {
                            if (!std.unicode.utf8ValidateSlice(new)) {
                                @branchHint(.cold);
                                return error.InvalidInput;
                            }
                        }

                        // Free potentially existing string/bytes before
                        // replacing field.
                        if (comptime Field == []const u8) {
                            const existing: []const u8 =
                                @field(result, field.name);
                            if (comptime field_info.defaultValue()) |default| {
                                if (default.ptr != existing.ptr and
                                    existing.len > 0)
                                {
                                    allocator.free(existing);
                                }
                            } else if (existing.len > 0) {
                                allocator.free(existing);
                            }
                        } else if (comptime Field == ?[]const u8) {
                            if (@field(result, field.name)) |existing| {
                                if (existing.len > 0) {
                                    if (comptime field_info.defaultValue()) |opt| {
                                        if (comptime opt != null) {
                                            if (opt.?.ptr != existing.ptr) {
                                                allocator.free(existing);
                                            }
                                        }
                                    } else {
                                        allocator.free(existing);
                                    }
                                }
                            }
                        } else unreachable;

                        @field(result, field.name) = new;
                    } else {
                        const val, const c = try decodeScalar(scalar, reader);
                        consumed += c;
                        @field(result, field.name) = val;
                    }
                },
                .@"enum" => {
                    const raw, const c = try decodeScalar(.int32, reader);
                    consumed += c;
                    const decoded = b: {
                        if (comptime field_ti == .optional) {
                            break :b enumFromRaw(
                                field_ti.optional.child,
                                raw,
                            );
                        } else {
                            break :b enumFromRaw(Field, raw);
                        }
                    };
                    if (decoded) |value| {
                        @field(result, field.name) = value;
                    } else if (comptime has_unknown_fields) {
                        // Unknown values of closed enums are unknown fields.
                        try appendUnknownVarint(allocator, &unknown_buf, tag.field, raw);
                    }
                },
                .packed_repeated => |repeated| {
                    const is_null = if (comptime field_ti == .optional) b: {
                        if (@field(result, field.name) == null) {
                            @field(result, field.name) = .empty;
                            break :b true;
                        }
                        break :b false;
                    } else false;
                    errdefer if (comptime field_ti == .optional) {
                        if (is_null) {
                            @field(result, field.name) = null;
                        }
                    };

                    // Packed encoding.
                    if (tag.wire_type == .len) {
                        const len, const c = try decodeScalar(.int32, reader);
                        consumed += c;

                        consumed += try decodeRepeated(
                            if (comptime field_ti == .optional)
                                &@field(result, field.name).?
                            else
                                &@field(result, field.name),
                            allocator,
                            repeated,
                            reader,
                            .{
                                .bytes = @intCast(len),
                                .unknown_fields = if (comptime has_unknown_fields) &unknown_buf else null,
                                .field_number = tag.field,
                                .extensions = options.extensions,
                            },
                        );
                    }
                    // Unpacked encoding, despite packed repeated field.
                    else {
                        consumed += try decodeRepeated(
                            if (comptime field_ti == .optional)
                                &@field(result, field.name).?
                            else
                                &@field(result, field.name),
                            allocator,
                            repeated,
                            reader,
                            .{
                                .unknown_fields = if (comptime has_unknown_fields) &unknown_buf else null,
                                .field_number = tag.field,
                                .extensions = options.extensions,
                            },
                        );
                    }
                },
                .repeated => |repeated| {
                    const is_null = if (comptime field_ti == .optional) b: {
                        if (@field(result, field.name) == null) {
                            @field(result, field.name) = .empty;
                            break :b true;
                        }
                        break :b false;
                    } else false;
                    errdefer if (comptime field_ti == .optional) {
                        if (is_null) {
                            @field(result, field.name) = null;
                        }
                    };
                    const len: ?usize = if (tag.wire_type == .len) b: {
                        const len, const c = try decodeScalar(.int32, reader);
                        consumed += c;
                        break :b @intCast(len);
                    } else null;
                    consumed += try decodeRepeated(
                        &@field(result, field.name),
                        allocator,
                        repeated,
                        reader,
                        .{
                            .bytes = len,
                            .group = if (comptime field_desc.isDelimited()) tag.field else null,
                            .verify_utf8 = comptime field_desc.verifiesUtf8(),
                            .unknown_fields = if (comptime has_unknown_fields) &unknown_buf else null,
                            .field_number = tag.field,
                            .extensions = options.extensions,
                        },
                    );
                },
                .submessage => {
                    const delimited = comptime field_desc.isDelimited();
                    std.debug.assert(tag.wire_type == if (delimited) .sgroup else .len);

                    // Delimited submessages have no length prefix; they end
                    // at the matching EGROUP tag instead.
                    const len: i32 = if (delimited) -1 else b: {
                        const len, const c = try decodeScalar(.int32, reader);
                        consumed += c;
                        if (len < 0) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }
                        break :b len;
                    };
                    const sub_options: SubmessageOptions = if (delimited)
                        .{ .group = tag.field, .extensions = options.extensions }
                    else
                        .{ .bytes = @intCast(len), .extensions = options.extensions };

                    // All submessages must be optional; submessages always
                    // have an explicit field presence, which means the
                    // absence of a submessage in wire encoding must always
                    // refer to the *lack of* a submessage rather than a
                    // "default" submessage.
                    std.debug.assert(field_ti == .optional);
                    const inner_ti = @typeInfo(field_ti.optional.child);

                    if (comptime inner_ti == .pointer) {
                        const SubMessage = inner_ti.pointer.child;
                        const is_null = b: {
                            if (@field(result, field.name) == null) {
                                @field(result, field.name) =
                                    try allocator.create(SubMessage);
                                errdefer allocator.destroy(
                                    @field(result, field.name).?,
                                );

                                @field(result, field.name).?.* =
                                    try protobuf.init(SubMessage, allocator);
                                break :b true;
                            }
                            break :b false;
                        };
                        errdefer if (is_null) {
                            @field(result, field.name).?.deinit(allocator);
                            allocator.destroy(@field(result, field.name).?);
                            @field(result, field.name) = null;
                        };

                        if (delimited or len > 0) {
                            const message_consumed = try decodeMessage(
                                @field(result, field.name).?,
                                allocator,
                                reader,
                                sub_options,
                            );
                            if (!delimited and message_consumed > len) {
                                @branchHint(.cold);
                                return error.InvalidInput;
                            }
                            consumed += message_consumed;
                        }
                    } else {
                        const SubMessage = field_ti.optional.child;
                        const is_null = b: {
                            if (@field(result, field.name) == null) {
                                @field(result, field.name) =
                                    try protobuf.init(SubMessage, allocator);
                                break :b true;
                            }
                            break :b false;
                        };
                        errdefer if (is_null) {
                            @field(result, field.name).?.deinit(allocator);
                            @field(result, field.name) = null;
                        };

                        if (delimited or len > 0) {
                            const message_consumed = try decodeMessage(
                                &@field(result, field.name).?,
                                allocator,
                                reader,
                                sub_options,
                            );
                            if (!delimited and message_consumed > len) {
                                @branchHint(.cold);
                                return error.InvalidInput;
                            }
                            consumed += message_consumed;
                        }
                    }
                },
                .oneof => |OneOf| {
                    // All oneof fields are necessarily optional, as none of
                    // the fields are active by default.
                    comptime std.debug.assert(field_ti == .optional);
                    comptime std.debug.assert(
                        field_ti.optional.child == OneOf,
                    );
                    const oneof_ti = comptime @typeInfo(OneOf).@"union";

                    const inner_desc_table = comptime OneOf._desc_table;
                    oo_fields: inline for (oneof_ti.fields) |oo_field| {
                        const inner_desc: protobuf.FieldDescriptor =
                            comptime @field(inner_desc_table, oo_field.name);

                        if (comptime inner_desc.field_number == null)
                            comptime continue :oo_fields;
                        if (inner_desc.field_number.? != tag.field) {
                            comptime continue :oo_fields;
                        }

                        if ((comptime inner_desc.toWire()) != tag.wire_type) {
                            @branchHint(.cold);
                            return error.InvalidInput;
                        }

                        const oo_field_ti = @typeInfo(oo_field.type);
                        switch (comptime inner_desc.ftype) {
                            .scalar => |scalar| {
                                if (comptime scalar.isSlice()) {
                                    std.debug.assert(tag.wire_type == .len);

                                    // `oneof` fields are always non-optional
                                    // as `oneof` has explicit presence.
                                    std.debug.assert(
                                        oo_field.type == []const u8,
                                    );

                                    std.debug.assert(tag.wire_type == .len);
                                    const len, const len_c =
                                        try decodeScalar(.int32, reader);
                                    consumed += len_c;

                                    if (len < 0) {
                                        @branchHint(.cold);
                                        return error.InvalidInput;
                                    }

                                    const new: []u8 = if (len > 0)
                                        try allocator.alloc(u8, @intCast(len))
                                    else
                                        &.{};
                                    errdefer if (len > 0) allocator.free(new);

                                    if (len > 0) {
                                        _ = try reader.readSliceAll(new);
                                        consumed += @intCast(len);
                                    }
                                    if (comptime inner_desc.verifiesUtf8()) {
                                        if (!std.unicode.utf8ValidateSlice(new)) {
                                            @branchHint(.cold);
                                            return error.InvalidInput;
                                        }
                                    }

                                    // Free potentially existing union field
                                    // just before replacing.
                                    protobuf.deinitOneof(
                                        &@field(result, field.name),
                                        allocator,
                                    );

                                    @field(result, field.name) = @unionInit(
                                        OneOf,
                                        oo_field.name,
                                        new,
                                    );
                                } else {
                                    const val, const c =
                                        try decodeScalar(scalar, reader);
                                    consumed += c;
                                    @field(result, field.name) = @unionInit(
                                        OneOf,
                                        oo_field.name,
                                        val,
                                    );
                                }
                            },
                            .@"enum" => {
                                const raw, const c =
                                    try decodeScalar(.int32, reader);
                                consumed += c;
                                const decoded = enumFromRaw(
                                    oo_field.type,
                                    raw,
                                ) orelse {
                                    // Unknown values of closed enums are
                                    // unknown fields; the oneof is untouched.
                                    if (comptime has_unknown_fields) {
                                        try appendUnknownVarint(allocator, &unknown_buf, tag.field, raw);
                                    }
                                    break :oo_fields;
                                };

                                // Free potentially existing union field just
                                // before replacing.
                                protobuf.deinitOneof(
                                    &@field(result, field.name),
                                    allocator,
                                );

                                @field(result, field.name) = @unionInit(
                                    OneOf,
                                    oo_field.name,
                                    decoded,
                                );
                            },
                            .submessage => {
                                const delimited = comptime inner_desc.isDelimited();
                                std.debug.assert(tag.wire_type == if (delimited) .sgroup else .len);

                                // Delimited submessages have no length prefix;
                                // they end at the matching EGROUP tag instead.
                                const len: i32 = if (delimited) -1 else b: {
                                    const len, const c =
                                        try decodeScalar(.int32, reader);
                                    consumed += c;

                                    if (len < 0) {
                                        @branchHint(.cold);
                                        return error.InvalidInput;
                                    }
                                    break :b len;
                                };
                                const sub_options: SubmessageOptions = if (delimited)
                                    .{ .group = tag.field, .extensions = options.extensions }
                                else
                                    .{ .bytes = @intCast(len), .extensions = options.extensions };

                                // Submessages are non-optional, as `oneof`s
                                // also have explicit presence.
                                comptime std.debug.assert(
                                    oo_field_ti == .@"struct" or
                                        oo_field_ti == .pointer,
                                );

                                const SubMessage =
                                    if (comptime oo_field_ti == .pointer)
                                        oo_field_ti.pointer.child
                                    else
                                        oo_field.type;

                                if (@field(result, field.name) != null) {
                                    // If a matching submessage field already
                                    // exists, the incoming submessage is
                                    // merged. Otherwise, the existing field
                                    // is freed and set to null.
                                    const incoming_tag = comptime @field(
                                        std.meta.Tag(OneOf),
                                        oo_field.name,
                                    );
                                    if (std.meta.activeTag(
                                        @field(result, field.name).?,
                                    ) != incoming_tag) {
                                        protobuf.deinitOneof(
                                            &@field(result, field.name),
                                            allocator,
                                        );

                                        std.debug.assert(@field(
                                            result,
                                            field.name,
                                        ) == null);
                                    }
                                }
                                const is_null =
                                    @field(result, field.name) == null;
                                if (comptime oo_field_ti == .pointer) {
                                    if (is_null) {
                                        @field(result, field.name) = @unionInit(
                                            OneOf,
                                            oo_field.name,
                                            try allocator.create(SubMessage),
                                        );
                                        @field(
                                            @field(result, field.name).?,
                                            oo_field.name,
                                        ) = try .init(allocator);
                                    }
                                    errdefer if (is_null) {
                                        @field(@field(
                                            result,
                                            field.name,
                                        ).?, oo_field.name).deinit(allocator);
                                        allocator.destroy(
                                            @field(result, field.name).?,
                                        );
                                        @field(result, field.name) = null;
                                    };

                                    if (delimited or len > 0) {
                                        const m_consumed = try decodeMessage(
                                            @field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            sub_options,
                                        );
                                        if (!delimited and m_consumed > len) {
                                            @branchHint(.cold);
                                            return error.InvalidInput;
                                        }
                                        consumed += m_consumed;
                                    }
                                } else {
                                    if (is_null) {
                                        @field(result, field.name) =
                                            @unionInit(
                                                OneOf,
                                                oo_field.name,
                                                try protobuf.init(
                                                    SubMessage,
                                                    allocator,
                                                ),
                                            );
                                    }
                                    errdefer if (is_null) {
                                        @field(
                                            @field(result, field.name).?,
                                            oo_field.name,
                                        ).deinit(allocator);
                                        @field(result, field.name) = null;
                                    };

                                    if (delimited or len > 0) {
                                        const m_consumed = try decodeMessage(
                                            &@field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            sub_options,
                                        );
                                        if (!delimited and m_consumed > len) {
                                            @branchHint(.cold);
                                            return error.InvalidInput;
                                        }
                                        consumed += m_consumed;
                                    }
                                }
                            },
                            .oneof,
                            .repeated,
                            .packed_repeated,
                            => unreachable,
                        }
                        break :oo_fields;
                    } else {
                        // Not a field of this oneof: try the next fields,
                        // which may include other oneofs.
                        continue :fields;
                    }
                },
            }
            comptime break;
        } else {
            consumed += try captureUnmatched(
                Result,
                allocator,
                reader,
                tag,
                if (comptime has_unknown_fields) &unknown_buf else null,
                if (comptime has_extensions) &extension_buf else null,
            );
        }
    }
    if (comptime has_unknown_fields) {
        try appendOwned(allocator, &result._unknown_fields, &unknown_buf);
    }
    if (comptime has_extensions) {
        try appendOwned(allocator, &result._extensions, &extension_buf);
        if (options.extensions) |registry| {
            try registry.validate(Result, result._extensions, allocator);
        }
    }
    return consumed;
}

/// Stores a field that matches no field of `Result`: in the extension records
/// when it is in an extension range, else in the unknown fields if they are
/// kept. Returns the number of bytes consumed after the tag.
fn captureUnmatched(
    comptime Result: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    tag: Tag,
    unknown: ?*std.ArrayList(u8),
    extensions: ?*std.ArrayList(u8),
) (std.Io.Reader.Error || std.mem.Allocator.Error || protobuf.DecodingError)!usize {
    if (comptime @hasDecl(Result, "_extensions_info")) {
        if (extensions) |buf| {
            inline for (Result._extensions_info.ranges) |range| {
                if (tag.field >= range[0] and tag.field < range[1]) {
                    return captureField(allocator, reader, tag, buf);
                }
            }
        }
    }
    if (unknown) |buf| return captureField(allocator, reader, tag, buf);
    return skipField(reader, tag);
}

/// Appends the bytes of `buf` to the owned slice `dest`. Messages may be
/// decoded several times (merged), so existing bytes are kept.
fn appendOwned(allocator: std.mem.Allocator, dest: *[]const u8, buf: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    if (buf.items.len == 0) return;
    if (dest.len == 0) {
        dest.* = try buf.toOwnedSlice(allocator);
        return;
    }
    const merged = try std.mem.concat(allocator, u8, &.{ dest.*, buf.items });
    allocator.free(dest.*);
    dest.* = merged;
}

pub fn skipField(reader: *std.Io.Reader, tag: Tag) !usize {
    var consumed: usize = 0;

    // If field number was not found, skip unknown field.
    log.debug(
        "Unknown field received in {any}\n",
        .{tag},
    );
    switch (tag.wire_type) {
        .fixed32 => {
            try reader.discardAll(4);
            consumed += 4;
        },
        .fixed64 => {
            try reader.discardAll(8);
            consumed += 8;
        },
        .len => {
            const skip, const c = try decodeScalar(.int32, reader);
            consumed += c;
            if (skip < 0) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            try reader.discardAll(@intCast(skip));
            consumed += @intCast(skip);
        },
        .varint => {
            _, const c = try decodeScalar(.uint64, reader);
            consumed += c;
        },
        .sgroup => {
            // Skip the entire group by consuming fields until the matching egroup tag.
            while (true) {
                const inner_tag, const tag_c = try Tag.decode(reader);
                consumed += tag_c;
                if (inner_tag.wire_type == .egroup) {
                    if (inner_tag.field != tag.field)
                        return error.InvalidInput;
                    break;
                }
                consumed += try skipField(reader, inner_tag);
            }
        },
        .egroup => {
            // An unmatched egroup tag is invalid.
            @branchHint(.cold);
            return error.InvalidInput;
        },
    }

    return consumed;
}

// Encode a runtime tag value as a varint to a buffer. Returns bytes written.
fn encodeTagBytes(tag: Tag, buf: *[10]u8) usize {
    const tag_u64: u64 = (@as(u64, tag.field) << 3) | @intFromEnum(tag.wire_type);
    var raw = tag_u64;
    var i: usize = 0;
    while (raw > 0x7F) {
        buf[i] = 0x80 | @as(u8, @intCast(raw & 0x7F));
        raw >>= 7;
        i += 1;
    }
    buf[i] = @intCast(raw & 0x7F);
    return i + 1;
}

// Capture an unknown field's tag+data bytes into buf, return total bytes consumed (after tag).
fn captureField(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    tag: Tag,
    buf: *std.ArrayList(u8),
) !usize {
    var tag_bytes: [10]u8 = undefined;
    const tag_len = encodeTagBytes(tag, &tag_bytes);
    try buf.appendSlice(allocator, tag_bytes[0..tag_len]);

    var data_consumed: usize = 0;
    switch (tag.wire_type) {
        .varint => {
            while (true) {
                const b = try reader.takeByte();
                try buf.append(allocator, b);
                data_consumed += 1;
                if (b & 0x80 == 0) break;
            }
        },
        .fixed32 => {
            const bytes = try reader.takeArray(4);
            try buf.appendSlice(allocator, bytes);
            data_consumed += 4;
        },
        .fixed64 => {
            const bytes = try reader.takeArray(8);
            try buf.appendSlice(allocator, bytes);
            data_consumed += 8;
        },
        .len => {
            var len_buf: [10]u8 = undefined;
            var len_i: usize = 0;
            var len_val: u64 = 0;
            var shift: u6 = 0;
            while (true) {
                const b = try reader.takeByte();
                len_buf[len_i] = b;
                len_i += 1;
                len_val |= @as(u64, b & 0x7F) << shift;
                shift += 7;
                if (b & 0x80 == 0) break;
            }
            try buf.appendSlice(allocator, len_buf[0..len_i]);
            data_consumed += len_i;
            const data = try reader.take(@intCast(len_val));
            try buf.appendSlice(allocator, data);
            data_consumed += @intCast(len_val);
        },
        .sgroup => {
            // Capture every nested field up to and including the matching
            // EGROUP tag, so that the group round-trips verbatim.
            while (true) {
                const inner_tag, const tag_c = try Tag.decode(reader);
                data_consumed += tag_c;
                if (inner_tag.wire_type == .egroup) {
                    if (inner_tag.field != tag.field) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }
                    const end_len = encodeTagBytes(inner_tag, &tag_bytes);
                    try buf.appendSlice(allocator, tag_bytes[0..end_len]);
                    break;
                }
                data_consumed += try captureField(allocator, reader, inner_tag, buf);
            }
        },
        .egroup => {
            // An unmatched egroup tag is invalid.
            @branchHint(.cold);
            return error.InvalidInput;
        },
    }
    return data_consumed;
}

test {
    _ = Tag;
    _ = ZigZag;
}
