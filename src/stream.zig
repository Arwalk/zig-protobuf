//! Streaming pull-decoder for protobuf messages.
//!
//! Where `protobuf.decode` materializes a whole message (allocating storage for
//! every dynamic field), `StreamDecoder` walks a `std.Io.Reader` one wire field
//! at a time and hands each one back as an `Event`. It never allocates: scalar
//! values are returned by value, and length-delimited fields (submessages,
//! strings, bytes) are surfaced as a `*std.Io.Reader` bounded to that field's
//! bytes, which the caller may recurse into, copy out of, or simply ignore.
//!
//! This addresses incremental / low-memory decoding (issue #30): you can decode
//! arbitrarily large or nested messages without buffering them in contiguous
//! memory and without the library taking over control flow.
//!
//! Usage:
//! ```zig
//! var sd = MyMessage.StreamDecoder.init(&reader);
//! while (try sd.next()) |item| switch (item) {
//!     .some_scalar => |v| { ... },
//!     .some_submessage => |limited| {        // limited: *std.Io.Reader
//!         var inner = Sub.StreamDecoder.init(limited);
//!         while (try inner.next()) |x| { ... }
//!     },
//!     .some_string => |limited| {
//!         var buf: [64]u8 = undefined;
//!         try limited.readSliceAll(buf[0..n]);
//!     },
//! };
//! ```
//!
//! Repeated fields emit one `Event` per element (packed and unpacked encodings
//! are both handled). `oneof` cases are flattened: each case becomes its own
//! top-level `Event` variant, matched by its own field number.
//!
//! Caveat: the decoder must not be copied after `init` — the `*std.Io.Reader`
//! handed out for length-delimited fields points into the decoder itself.
//! The content of a `*std.Io.Reader` must also be used before another call to `next`
//! as the decoder forwards into the initial `*std.Io.Reader`, discarding the leftovers
//! of the inner reader.
//!
//! Caveat2: Because the decoder parses lazily, we have no mean to know if the entire message
//! was properly encoded in the first place. If any encoding error happens in the middle of the process
//! it is the user's responsibility to manage the consequences. This implies that the stream decoder
//! should only used with trusted sources of protobuf messages.

const std = @import("std");
const protobuf = @import("protobuf.zig");
const wire = @import("wire.zig");
const FieldType = protobuf.FieldType;

/// Build a `StreamDecoder` type for the generated message type `T`.
/// `T` must expose a `_desc_table` (every generated message does).
pub fn StreamDecoder(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Scratch buffer handed to the length-limited sub-reader so that a
        /// nested decoder can read tags/scalars out of it without allocating.
        const scratch_size = 64;

        /// Tagged union with one variant per leaf wire field of `T` (regular
        /// fields plus flattened `oneof` cases). See module docs for the payload
        /// conventions.
        pub const Event = EventUnion(T);

        /// Errors `next` may return. No allocator is involved.
        pub const Error = protobuf.DecodingError || std.Io.Reader.Error;

        /// Decoder state. This is an implementation detail: callers should only
        /// touch the decoder through `init` and `next`, never reach into these
        /// fields.
        const Internals = struct {
            source: *std.Io.Reader,
            scratch: [scratch_size]u8 = undefined,
            limited: std.Io.Reader.Limited = undefined,
            /// A length-delimited sub-reader was handed out and its leftover
            /// bytes must be drained before the next tag is read.
            pending_limited: bool = false,
            /// Field number of the packed repeated run currently being emitted,
            /// if any, together with how many bytes of it remain.
            packed_field: ?u32 = null,
            packed_remaining: usize = 0,
        };

        internals: Internals,

        pub fn init(source: *std.Io.Reader) Self {
            return .{ .internals = .{ .source = source } };
        }

        /// Decode the next wire field. Returns `null` at end of stream (top
        /// level) or at the end of a limited sub-reader (nested decoding).
        /// Invalidates any previous `*std.Io.Reader` item that was returned by this method
        pub fn next(self: *Self) Error!?Event {
            // Skip over any bytes the caller didn't consume from the previous
            // length-delimited field, so we're positioned on the next tag.
            if (self.internals.pending_limited) {
                _ = try self.internals.limited.interface.discardRemaining();
                self.internals.pending_limited = false;
            }

            // Continue emitting elements of an in-progress packed repeated run.
            if (self.internals.packed_field != null) {
                if (self.internals.packed_remaining > 0) return try self.continuePacked();
                self.internals.packed_field = null;
            }

            while (true) {
                const tag: wire.Tag, _ = wire.Tag.decode(self.internals.source) catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => |e| return e,
                };
                if (try self.dispatch(tag)) |ev| return ev;
                // Otherwise the field was matched-but-empty (empty packed run)
                // or unknown-and-skipped; loop for the next tag.
            }
        }

        /// Match `tag` against the descriptor table and produce its event.
        /// Returns `null` when nothing was emitted (empty packed run, or an
        /// unknown field that was skipped).
        fn dispatch(self: *Self, tag: wire.Tag) Error!?Event {
            const desc_table = T._desc_table;
            inline for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |sf| {
                const field_desc: protobuf.FieldDescriptor = comptime @field(desc_table, sf.name);
                if (comptime field_desc.ftype == .oneof) {
                    const OneOf = comptime field_desc.ftype.oneof;
                    const inner = comptime OneOf._desc_table;
                    inline for (@typeInfo(@TypeOf(inner)).@"struct".fields) |oo| {
                        const idesc: protobuf.FieldDescriptor = comptime @field(inner, oo.name);
                        if (comptime idesc.field_number != null) {
                            if (idesc.field_number.? == tag.field) {
                                if (idesc.ftype.toWire() != tag.wire_type) return error.InvalidInput;
                                return try self.emitSingle(oo.name, comptime idesc.ftype, @FieldType(OneOf, oo.name));
                            }
                        }
                    }
                } else if (comptime field_desc.field_number != null) {
                    if (field_desc.field_number.? == tag.field) {
                        return try self.handleField(sf.name, comptime field_desc, tag);
                    }
                }
            }
            // Unknown field: skip it and signal "no event".
            _ = try wire.skipField(self.internals.source, tag);
            return null;
        }

        fn handleField(
            self: *Self,
            comptime name: []const u8,
            comptime field_desc: protobuf.FieldDescriptor,
            tag: wire.Tag,
        ) Error!?Event {
            const Declared = @FieldType(T, name);
            switch (comptime field_desc.ftype) {
                .scalar, .@"enum", .submessage => {
                    if (tag.wire_type != comptime field_desc.ftype.toWire()) return error.InvalidInput;
                    return try self.emitSingle(name, comptime field_desc.ftype, Declared);
                },
                .packed_repeated => |rep| {
                    if (tag.wire_type != .len and tag.wire_type != comptime rep.toWire()) return error.InvalidInput;
                    return try self.handleRepeated(name, rep, Declared, tag);
                },
                .repeated => |rep| {
                    if (tag.wire_type != .len and tag.wire_type != comptime rep.toWire()) return error.InvalidInput;
                    return try self.handleRepeated(name, rep, Declared, tag);
                },
                .oneof => unreachable,
            }
        }

        /// Emit a single (non-repeated) scalar/enum/submessage field.
        fn emitSingle(
            self: *Self,
            comptime name: []const u8,
            comptime ftype: FieldType,
            comptime Declared: type,
        ) Error!Event {
            switch (comptime ftype) {
                .scalar => |s| {
                    if (comptime s.isSlice()) {
                        return @unionInit(Event, name, try self.openLen());
                    }
                    const val, _ = try wire.decodeScalar(s, self.internals.source);
                    return @unionInit(Event, name, val);
                },
                .@"enum" => {
                    const E = comptime UnwrapOptional(Declared);
                    const raw, _ = try wire.decodeScalar(.int32, self.internals.source);
                    const decoded = enumFromRaw(E, raw) orelse return error.InvalidInput;
                    return @unionInit(Event, name, decoded);
                },
                .submessage => return @unionInit(Event, name, try self.openLen()),
                else => unreachable,
            }
        }

        fn handleRepeated(
            self: *Self,
            comptime name: []const u8,
            comptime rep: FieldType.Repeated,
            comptime Declared: type,
            tag: wire.Tag,
        ) Error!?Event {
            switch (comptime rep) {
                .scalar => |s| {
                    if (comptime s.isSlice()) {
                        // repeated string/bytes are always individual LEN fields.
                        return @unionInit(Event, name, try self.openLen());
                    }
                    if (tag.wire_type == .len) return try self.beginPacked(tag);
                    const val, _ = try wire.decodeScalar(s, self.internals.source);
                    return @unionInit(Event, name, val);
                },
                .@"enum" => {
                    if (tag.wire_type == .len) return try self.beginPacked(tag);
                    const E = comptime ElementType(Declared);
                    const raw, _ = try wire.decodeScalar(.int32, self.internals.source);
                    const decoded = enumFromRaw(E, raw) orelse return error.InvalidInput;
                    return @unionInit(Event, name, decoded);
                },
                .submessage => return @unionInit(Event, name, try self.openLen()),
            }
        }

        /// Read the length prefix of a length-delimited field and hand back a
        /// reader bounded to its bytes. The leftover is drained on the next
        /// `next` call.
        fn openLen(self: *Self) Error!*std.Io.Reader {
            const len: i32, _ = try wire.decodeScalar(.int32, self.internals.source);
            if (len < 0) return error.InvalidInput;
            self.internals.limited = self.internals.source.limited(std.Io.Limit.limited(@intCast(len)), &self.internals.scratch);
            self.internals.pending_limited = true;
            return &self.internals.limited.interface;
        }

        /// Start a packed repeated run, then emit its first element.
        fn beginPacked(self: *Self, tag: wire.Tag) Error!?Event {
            const len: i32, _ = try wire.decodeScalar(.int32, self.internals.source);
            if (len < 0) return error.InvalidInput;
            self.internals.packed_remaining = @intCast(len);
            if (self.internals.packed_remaining == 0) return null; // empty packed run, no event
            self.internals.packed_field = tag.field;
            return try self.continuePacked();
        }

        /// Emit one more element of the in-progress packed run.
        fn continuePacked(self: *Self) Error!Event {
            const fnum = self.internals.packed_field.?;
            const desc_table = T._desc_table;
            inline for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |sf| {
                const field_desc: protobuf.FieldDescriptor = comptime @field(desc_table, sf.name);
                switch (comptime field_desc.ftype) {
                    .repeated, .packed_repeated => |rep| {
                        if (comptime field_desc.field_number != null) {
                            if (field_desc.field_number.? == fnum) {
                                return try self.decodePackedOne(sf.name, rep, @FieldType(T, sf.name));
                            }
                        }
                    },
                    else => {},
                }
            }
            unreachable; // packed_field was only set from a matched repeated field
        }

        fn decodePackedOne(
            self: *Self,
            comptime name: []const u8,
            comptime rep: FieldType.Repeated,
            comptime Declared: type,
        ) Error!Event {
            switch (comptime rep) {
                .scalar => |s| {
                    comptime std.debug.assert(!s.isSlice());
                    const val, const c = try wire.decodeScalar(s, self.internals.source);
                    try self.consumePacked(c);
                    return @unionInit(Event, name, val);
                },
                .@"enum" => {
                    const E = comptime ElementType(Declared);
                    const raw, const c = try wire.decodeScalar(.int32, self.internals.source);
                    const decoded = enumFromRaw(E, raw) orelse return error.InvalidInput;
                    try self.consumePacked(c);
                    return @unionInit(Event, name, decoded);
                },
                .submessage => unreachable, // submessages are never packed
            }
        }

        fn consumePacked(self: *Self, c: usize) Error!void {
            if (c > self.internals.packed_remaining) return error.InvalidInput; // element straddled the run
            self.internals.packed_remaining -= c;
            if (self.internals.packed_remaining == 0) self.internals.packed_field = null;
        }
    };
}

/// The `Event` union for `T`: one variant per leaf wire field.
fn EventUnion(comptime T: type) type {
    @setEvalBranchQuota(50_000);
    const desc_table = T._desc_table;
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    for (@typeInfo(@TypeOf(desc_table)).@"struct".fields) |sf| {
        const field_desc: protobuf.FieldDescriptor = @field(desc_table, sf.name);
        if (field_desc.ftype == .oneof) {
            const OneOf = field_desc.ftype.oneof;
            const inner = OneOf._desc_table;
            for (@typeInfo(@TypeOf(inner)).@"struct".fields) |oo| {
                const idesc: protobuf.FieldDescriptor = @field(inner, oo.name);
                names = names ++ [_][]const u8{oo.name};
                types = types ++ [_]type{PayloadType(idesc.ftype, @FieldType(OneOf, oo.name))};
            }
        } else if (field_desc.field_number != null) {
            names = names ++ [_][]const u8{sf.name};
            types = types ++ [_]type{PayloadType(field_desc.ftype, @FieldType(T, sf.name))};
        }
    }
    const count = names.len;
    const IntTag = if (count == 0) u0 else std.math.IntFittingRange(0, count - 1);
    const name_arr: [count][]const u8 = names[0..count].*;
    const type_arr: [count]type = types[0..count].*;
    const TagEnum = @Enum(IntTag, .exhaustive, &name_arr, &std.simd.iota(IntTag, count));
    const attrs: [count]std.builtin.Type.UnionField.Attributes = @splat(.{});
    return @Union(.auto, TagEnum, &name_arr, &type_arr, &attrs);
}

/// Payload type for one leaf field's event variant.
fn PayloadType(comptime ftype: FieldType, comptime Declared: type) type {
    return switch (ftype) {
        .scalar => |s| if (s.isSlice()) *std.Io.Reader else s.toType(),
        .@"enum" => UnwrapOptional(Declared),
        .submessage => *std.Io.Reader,
        .repeated, .packed_repeated => |rep| switch (rep) {
            .scalar => |s| if (s.isSlice()) *std.Io.Reader else s.toType(),
            .@"enum" => ElementType(Declared),
            .submessage => *std.Io.Reader,
        },
        .oneof => unreachable,
    };
}

/// `?U` -> `U`, otherwise `T` unchanged.
fn UnwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Element type of a (possibly optional) `std.ArrayList(E)` field.
fn ElementType(comptime Declared: type) type {
    const List = UnwrapOptional(Declared);
    return @typeInfo(@FieldType(List, "items")).pointer.child;
}

/// Convert a raw int32 to enum `E`, validating against known values for
/// exhaustive enums (mirrors `wire.zig`'s private helper).
fn enumFromRaw(comptime E: type, raw: i32) ?E {
    if (comptime !@typeInfo(E).@"enum".is_exhaustive) return @enumFromInt(raw);
    return std.enums.fromInt(E, raw);
}

// ---------------------------------------------------------------------------
// Tests (use hand-written message types so they run without protoc).
// ---------------------------------------------------------------------------

const testing = std.testing;
const fd = protobuf.fd;

/// Encode `msg` with the canonical encoder into an allocated buffer.
fn encodeToOwned(msg: anytype, allocator: std.mem.Allocator) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    try protobuf.encode(&w.writer, allocator, msg);
    return w.toOwnedSlice();
}

const Scalars = struct {
    int32: i32 = 0,
    sint32: i32 = 0,
    uint64: u64 = 0,
    a_bool: bool = false,
    a_float: f32 = 0,

    pub const _desc_table = .{
        .int32 = fd(1, .{ .scalar = .int32 }),
        .sint32 = fd(2, .{ .scalar = .sint32 }),
        .uint64 = fd(3, .{ .scalar = .uint64 }),
        .a_bool = fd(4, .{ .scalar = .bool }),
        .a_float = fd(5, .{ .scalar = .float }),
    };
};

test "stream: scalar fields" {
    const src: Scalars = .{ .int32 = -7, .sint32 = -7, .uint64 = 1 << 40, .a_bool = true, .a_float = 1.5 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(Scalars).init(&reader);

    var got: Scalars = .{};
    while (try sd.next()) |item| switch (item) {
        .int32 => |v| got.int32 = v,
        .sint32 => |v| got.sint32 = v,
        .uint64 => |v| got.uint64 = v,
        .a_bool => |v| got.a_bool = v,
        .a_float => |v| got.a_float = v,
    };
    try testing.expectEqual(src, got);
}

const WithString = struct {
    before: u32 = 0,
    name: []const u8 = &.{},
    after: u32 = 0,

    pub const _desc_table = .{
        .before = fd(1, .{ .scalar = .uint32 }),
        .name = fd(2, .{ .scalar = .string }),
        .after = fd(3, .{ .scalar = .uint32 }),
    };
};

test "stream: string handed out as limited reader, drains for following field" {
    const src: WithString = .{ .before = 11, .name = "hello world", .after = 22 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(WithString).init(&reader);

    try testing.expectEqual(@as(u32, 11), (try sd.next()).?.before);

    // Read the string fully out of the limited sub-reader.
    {
        const ev = (try sd.next()).?;
        const limited = ev.name;
        var buf: [32]u8 = undefined;
        const n = try limited.readSliceShort(&buf);
        try testing.expectEqualStrings("hello world", buf[0..n]);
    }

    // The following field must still decode correctly.
    try testing.expectEqual(@as(u32, 22), (try sd.next()).?.after);
    try testing.expectEqual(@as(?StreamDecoder(WithString).Event, null), try sd.next());
}

test "stream: ignored limited reader is drained automatically" {
    const src: WithString = .{ .before = 1, .name = "skip me entirely", .after = 2 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(WithString).init(&reader);

    try testing.expectEqual(@as(u32, 1), (try sd.next()).?.before);
    _ = (try sd.next()).?.name; // do not read from it
    try testing.expectEqual(@as(u32, 2), (try sd.next()).?.after);
}

test "stream: partially read limited reader drains the leftover for the following field" {
    const src: WithString = .{ .before = 11, .name = "hello world", .after = 22 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(WithString).init(&reader);

    try testing.expectEqual(@as(u32, 11), (try sd.next()).?.before);

    // Read only the first few bytes of the 11-byte string, leaving the rest
    // buffered/unread in the limited sub-reader.
    {
        const limited = (try sd.next()).?.name;
        var buf: [4]u8 = undefined;
        try limited.readSliceAll(&buf);
        try testing.expectEqualStrings("hell", &buf);
    }

    // The unread "o world" tail must be drained so the next field decodes.
    try testing.expectEqual(@as(u32, 22), (try sd.next()).?.after);
    try testing.expectEqual(@as(?StreamDecoder(WithString).Event, null), try sd.next());
}

const Packed = struct {
    values: std.ArrayList(u32) = .empty,

    pub const _desc_table = .{
        .values = fd(1, .{ .packed_repeated = .{ .scalar = .uint32 } }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
};

test "stream: packed repeated emits one event per element" {
    var src: Packed = .{};
    defer src.deinit(testing.allocator);
    try src.values.appendSlice(testing.allocator, &.{ 1, 2, 300, 40000, 5 });

    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(Packed).init(&reader);

    var collected: std.ArrayList(u32) = .empty;
    defer collected.deinit(testing.allocator);
    while (try sd.next()) |item| switch (item) {
        .values => |v| try collected.append(testing.allocator, v),
    };
    try testing.expectEqualSlices(u32, &.{ 1, 2, 300, 40000, 5 }, collected.items);
}

const Unpacked = struct {
    values: std.ArrayList(u32) = .empty,

    // `.repeated` (not `.packed_repeated`) encodes one individually-tagged
    // element per value, which the decoder emits via the non-packed path.
    pub const _desc_table = .{
        .values = fd(1, .{ .repeated = .{ .scalar = .uint32 } }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
};

test "stream: unpacked repeated emits one event per individually-tagged element" {
    var src: Unpacked = .{};
    defer src.deinit(testing.allocator);
    try src.values.appendSlice(testing.allocator, &.{ 1, 2, 300, 40000, 5 });

    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(Unpacked).init(&reader);

    var collected: std.ArrayList(u32) = .empty;
    defer collected.deinit(testing.allocator);
    while (try sd.next()) |item| switch (item) {
        .values => |v| try collected.append(testing.allocator, v),
    };
    try testing.expectEqualSlices(u32, &.{ 1, 2, 300, 40000, 5 }, collected.items);
}

const Inner = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub const _desc_table = .{
        .x = fd(1, .{ .scalar = .int32 }),
        .y = fd(2, .{ .scalar = .int32 }),
    };
};

const Outer = struct {
    tag: u32 = 0,
    inner: ?Inner = null,
    trailer: u32 = 0,

    pub const _desc_table = .{
        .tag = fd(1, .{ .scalar = .uint32 }),
        .inner = fd(2, .submessage),
        .trailer = fd(3, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
};

test "stream: submessage recursed via nested decoder, then parent resumes" {
    const src: Outer = .{ .tag = 9, .inner = .{ .x = -1, .y = 2 }, .trailer = 99 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(Outer).init(&reader);

    try testing.expectEqual(@as(u32, 9), (try sd.next()).?.tag);

    {
        const limited = (try sd.next()).?.inner;
        var inner_sd = StreamDecoder(Inner).init(limited);
        var got: Inner = .{};
        while (try inner_sd.next()) |item| switch (item) {
            .x => |v| got.x = v,
            .y => |v| got.y = v,
        };
        try testing.expectEqual(Inner{ .x = -1, .y = 2 }, got);
    }

    try testing.expectEqual(@as(u32, 99), (try sd.next()).?.trailer);
}

test "stream: submessage skipped (sub-reader ignored), parent resumes" {
    const src: Outer = .{ .tag = 9, .inner = .{ .x = -1, .y = 2 }, .trailer = 99 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(Outer).init(&reader);

    try testing.expectEqual(@as(u32, 9), (try sd.next()).?.tag);
    _ = (try sd.next()).?.inner; // ignore the submessage entirely
    try testing.expectEqual(@as(u32, 99), (try sd.next()).?.trailer);
}

const Color = enum(i32) { red = 0, green = 1, blue = 2 };

const OneofMsg = struct {
    head: u32 = 0,
    choice: ?choice_union = null,

    pub const _choice_case = enum { a_number, a_string, a_color };
    pub const choice_union = union(_choice_case) {
        a_number: i32,
        a_string: []const u8,
        a_color: Color,

        pub const _desc_table = .{
            .a_number = fd(2, .{ .scalar = .int32 }),
            .a_string = fd(3, .{ .scalar = .string }),
            .a_color = fd(4, .@"enum"),
        };
    };

    pub const _desc_table = .{
        .head = fd(1, .{ .scalar = .uint32 }),
        .choice = fd(null, .{ .oneof = choice_union }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
};

test "stream: oneof cases are flattened into top-level events" {
    const src: OneofMsg = .{ .head = 5, .choice = .{ .a_color = .blue } };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(OneofMsg).init(&reader);

    try testing.expectEqual(@as(u32, 5), (try sd.next()).?.head);
    switch ((try sd.next()).?) {
        .a_color => |c| try testing.expectEqual(Color.blue, c),
        else => return error.UnexpectedVariant,
    }
    try testing.expectEqual(@as(?StreamDecoder(OneofMsg).Event, null), try sd.next());
}

test "stream: unknown fields are skipped" {
    // Encode a richer message, decode it as a struct that only knows field 1.
    const src: WithString = .{ .before = 7, .name = "ignored", .after = 8 };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    const OnlyBefore = struct {
        before: u32 = 0,
        pub const _desc_table = .{ .before = fd(1, .{ .scalar = .uint32 }) };
    };

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = StreamDecoder(OnlyBefore).init(&reader);

    try testing.expectEqual(@as(u32, 7), (try sd.next()).?.before);
    // Fields 2 (string) and 3 (uint32) are unknown and skipped.
    try testing.expectEqual(@as(?StreamDecoder(OnlyBefore).Event, null), try sd.next());
}
