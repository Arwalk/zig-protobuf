//! Protocol Buffers definitions and functions for wire encoding/decoding.
const std = @import("std");

const protobuf = @import("protobuf.zig");
const log = std.log.scoped(.zig_protobuf);

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
        const raw_result: u32, const consumed: usize =
            try decodeScalar(.uint32, reader);

        const invalid_wire_type = (raw_result & 0x7) > 5;
        if (invalid_wire_type) {
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
    reader: *std.Io.Reader,
) (std.Io.Reader.Error || protobuf.DecodingError)!struct {
    /// Resulting decoded scalar.
    scalar.toType(),
    /// Number of bytes consumed from reader.
    usize,
} {
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
        const consumed = for (0..max_bytes) |i| {
            const b = try reader.takeByte();
            const num = b & 0x7F;
            val |= @as(Result, num) << @intCast(7 * i);
            if (b >> 7 == 0) break i + 1;
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        };

        // As `int32` may receive `int64` equivalent encoding values, ensure
        // that values actually fit within `int32` range.
        if (comptime scalar == .int32) {
            // Encoded as `int32`
            if (val & @as(i64, @bitCast(@as(u64, 0xFFFFFFFF00000000))) == 0) {
                return .{ @truncate(val), consumed };
            }

            if (val < std.math.minInt(i32) or val > std.math.maxInt(i32)) {
                @branchHint(.cold);
                return error.InvalidInput;
            }

            return .{ @intCast(val), consumed };
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
        const b = try reader.takeByte();
        if (b == 0) {
            return .{ false, 1 };
        } else if (b == 1) {
            return .{ true, 1 };
        } else {
            @branchHint(.cold);
            return error.InvalidInput;
        }
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
        var reader: std.Io.Reader = .fixed(bytes);

        const max_u64 = decodeScalar(.int32, &reader);
        try std.testing.expectError(error.InvalidInput, max_u64);
    }

    { // Barely oversized `int32` value
        const bytes: []const u8 = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 };
        var reader: std.Io.Reader = .fixed(bytes);

        const barely_too_big = decodeScalar(.int32, &reader);
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
    },
) (std.Io.Reader.Error || std.mem.Allocator.Error || protobuf.DecodingError)!usize {
    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const ResultList = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const Result = comptime @typeInfo(
        @FieldType(ResultList, "items"),
    ).pointer.child;
    comptime std.debug.assert(ResultList == std.ArrayListUnmanaged(Result));

    const current_capacity = result.capacity;
    errdefer result.shrinkAndFree(allocator, current_capacity);

    const current_items = result.items.len;
    errdefer result.shrinkRetainingCapacity(current_items);

    switch (comptime field) {
        .scalar => |scalar| {
            if (comptime scalar.isSlice()) {
                // string/bytes are length-delimited, and cannot be packed.
                std.debug.assert(options.bytes != null);

                const bytes = try reader.readAlloc(allocator, options.bytes.?);
                errdefer allocator.free(bytes);

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
                    const decoded = std.enums.fromInt(Result, raw) orelse {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    };
                    try result.append(allocator, decoded);
                    consumed += c;
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
                const decoded = std.enums.fromInt(Result, raw) orelse {
                    @branchHint(.cold);
                    return error.InvalidInput;
                };
                try result.append(allocator, decoded);
                return consumed;
            }
        },
        .submessage => {
            // Submessages are length-delimited, and cannot be packed.
            std.debug.assert(options.bytes != null);

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
                .{ .bytes = options.bytes },
            );
            if (consumed > options.bytes.?) {
                @branchHint(.cold);
                return error.InvalidInput;
            }
            return consumed;
        },
    }
}

test decodeRepeated {
    // length delimited message including a list of varints
    {
        const bytes: []const u8 = &.{ 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
        var list: std.ArrayListUnmanaged(u32) = .empty;
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
}

/// Decode a message from reader.
pub fn decodeMessage(
    result: anytype,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: struct {
        /// Number of bytes to parse. Provided for all submessages.
        bytes: ?usize = null,
    },
) (std.Io.Reader.Error || std.mem.Allocator.Error || protobuf.DecodingError)!usize {
    comptime std.debug.assert(@typeInfo(@TypeOf(result)) == .pointer);
    const Result = comptime @typeInfo(@TypeOf(result)).pointer.child;
    const ResultField = std.meta.FieldEnum(Result);
    comptime std.debug.assert(@TypeOf(result) == *Result);
    const desc_table = Result._desc_table;

    var consumed: usize = 0;
    main_loop: while (true) {
        const tag: Tag, const tag_c = b: {
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

        @setEvalBranchQuota(40_000);
        inline for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |field| {
            const field_desc: protobuf.FieldDescriptor =
                comptime @field(desc_table, field.name);
            const field_info: std.builtin.Type.StructField =
                std.meta.fieldInfo(Result, @field(ResultField, field.name));

            if (comptime field_desc.ftype != .oneof) {
                if (comptime field_desc.field_number == null)
                    comptime continue;
                const fnum = comptime field_desc.field_number.?;
                if (fnum != tag.field) comptime continue;
                if (comptime field_desc.ftype == .packed_repeated) {
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
                            break :b std.enums.fromInt(
                                field_ti.optional.child,
                                raw,
                            );
                        } else {
                            break :b std.enums.fromInt(Field, raw);
                        }
                    } orelse {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    };
                    @field(result, field.name) = decoded;
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
                            .{ .bytes = @intCast(len) },
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
                            .{},
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
                        .{ .bytes = len },
                    );
                },
                .submessage => {
                    std.debug.assert(tag.wire_type == .len);

                    const len, const c = try decodeScalar(.int32, reader);
                    consumed += c;
                    if (len < 0) {
                        @branchHint(.cold);
                        return error.InvalidInput;
                    }

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

                        if (len > 0) {
                            const message_consumed = try decodeMessage(
                                @field(result, field.name).?,
                                allocator,
                                reader,
                                .{ .bytes = @intCast(len) },
                            );
                            if (message_consumed > len) {
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

                        if (len > 0) {
                            const message_consumed = try decodeMessage(
                                &@field(result, field.name).?,
                                allocator,
                                reader,
                                .{ .bytes = @intCast(len) },
                            );
                            if (message_consumed > len) {
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

                        if (inner_desc.ftype.toWire() != tag.wire_type) {
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
                                const decoded = std.enums.fromInt(
                                    oo_field.type,
                                    raw,
                                ) orelse {
                                    @branchHint(.cold);
                                    return error.InvalidInput;
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
                                std.debug.assert(tag.wire_type == .len);

                                const len, const c =
                                    try decodeScalar(.int32, reader);
                                consumed += c;

                                if (len < 0) {
                                    @branchHint(.cold);
                                    return error.InvalidInput;
                                }

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

                                    if (len > 0) {
                                        const m_consumed = try decodeMessage(
                                            @field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            .{ .bytes = @intCast(len) },
                                        );
                                        if (m_consumed > len) {
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

                                    if (len > 0) {
                                        const m_consumed = try decodeMessage(
                                            &@field(
                                                @field(result, field.name).?,
                                                oo_field.name,
                                            ),
                                            allocator,
                                            reader,
                                            .{ .bytes = @intCast(len) },
                                        );
                                        if (m_consumed > len) {
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
                    } else consumed += try skipField(reader, tag);
                },
            }
            comptime break;
        } else consumed += try skipField(reader, tag);
    }
    return consumed;
}

fn skipField(reader: *std.Io.Reader, tag: Tag) !usize {
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
        .sgroup, .egroup => {
            // `sgroup`/`egroup` not supported.
        },
    }

    return consumed;
}

test {
    _ = Tag;
    _ = ZigZag;
}
