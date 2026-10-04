//! Protobuf extensions.
//!
//! A message that declares extension ranges (`extensions 100 to 199;`) stores
//! its extension fields in `_extensions`, as raw wire records. Each generated
//! extension is an `Extension` type, which gives typed access to one of them:
//!
//! ```zig
//! try pb.my_extension.set(&msg, allocator, 42);
//! var value = try pb.my_extension.get(msg, allocator); // ?i32
//! defer pb.my_extension.deinitValue(&value, allocator);
//! ```
//!
//! Extensions round-trip without any setup. An `ExtensionRegistry` is only
//! needed to validate extensions when decoding (UTF-8, well-formed values) and
//! to encode or decode them as JSON, where their name is `[full.name]`.

const std = @import("std");
const protobuf = @import("protobuf.zig");
const wire = @import("wire.zig");
const json = @import("json.zig");

pub const DecodeError = protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error;

/// Describes the extension `full_name` of the message `Extendee_`.
///
/// `Value_` is the type of the extension value: `?T` for singular extensions,
/// which always have explicit presence, and `std.ArrayList(T)` for repeated
/// extensions. `default_value` is the declared `[default = ...]` value, or
/// null.
pub fn Extension(
    comptime Extendee_: type,
    comptime Value_: type,
    comptime field: protobuf.FieldDescriptor,
    comptime name: []const u8,
    comptime default_value: anytype,
    comptime field_options: anytype,
) type {
    if (!@hasField(Extendee_, "_extensions")) {
        @compileError(@typeName(Extendee_) ++ " declares no extension range for " ++ name);
    }

    return struct {
        /// The extended message.
        pub const Extendee = Extendee_;
        /// Type of the extension value.
        pub const Value = Value_;
        /// Fully qualified name, used as `[full_name]` in JSON.
        pub const full_name = name;
        pub const field_number: u29 = field.field_number.?;
        pub const descriptor = field;
        /// Declared default value, or null. Singular extensions are `null`
        /// when not set; their value is then `default`.
        pub const default = default_value;
        /// Options of the extension field, as an anonymous struct of its set
        /// options (see the `_field_options` of messages). Empty when it has none.
        pub const options = field_options;

        const empty: Value_ = if (@typeInfo(Value_) == .optional) null else .empty;

        /// Message with the extension as its only field. It reuses the regular
        /// encoding, decoding and JSON logic for the extension value.
        pub const Holder = struct {
            value: Value_ = empty,

            pub const _desc_table = .{ .value = field };

            pub fn jsonParse(
                allocator: std.mem.Allocator,
                source: anytype,
                parse_options: std.json.ParseOptions,
            ) !@This() {
                return json.parse(@This(), allocator, source, parse_options);
            }
        };

        /// Returns the value of the extension. The caller owns the value and
        /// frees it with `deinitValue`.
        pub fn get(msg: Extendee_, allocator: std.mem.Allocator) DecodeError!Value_ {
            return decodeValue(msg._extensions, allocator, null);
        }

        /// Returns the value of the extension from an encoded `Extendee`, such
        /// as the `@"#raw"` field of the options emitted by the generator,
        /// which holds an encoded `google.protobuf.*Options` message. The
        /// caller frees the value with `deinitValue`.
        pub fn getFromBytes(encoded: []const u8, allocator: std.mem.Allocator) DecodeError!Value_ {
            return decodeValue(encoded, allocator, null);
        }

        /// Whether the extension is set in `msg`.
        pub fn has(msg: Extendee_) bool {
            return containsField(msg._extensions, field_number);
        }

        /// Sets the extension of `msg` to a copy of `value`.
        pub fn set(msg: *Extendee_, allocator: std.mem.Allocator, value: Value_) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
            var w: std.Io.Writer.Allocating = .init(allocator);
            defer w.deinit();
            try protobuf.encode(&w.writer, allocator, Holder{ .value = value });
            try replaceField(allocator, &msg._extensions, field_number, w.written());
        }

        /// Removes the extension from `msg`.
        pub fn clear(msg: *Extendee_, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            try replaceField(allocator, &msg._extensions, field_number, &.{});
        }

        /// Frees a value returned by `get`.
        pub fn deinitValue(value: *Value_, allocator: std.mem.Allocator) void {
            var holder: Holder = .{ .value = value.* };
            protobuf.deinit(allocator, &holder);
            value.* = empty;
        }

        fn decodeValue(
            records: []const u8,
            allocator: std.mem.Allocator,
            registry: ?*const ExtensionRegistry,
        ) DecodeError!Value_ {
            // The holder only knows this extension, so the other records
            // are skipped.
            var holder: Holder = .{};
            errdefer protobuf.deinit(allocator, &holder);
            var reader: std.Io.Reader = .fixed(records);
            _ = try wire.decodeMessage(&holder, allocator, &reader, .{ .extensions = registry });
            return holder.value;
        }

        fn validate(records: []const u8, allocator: std.mem.Allocator, registry: *const ExtensionRegistry) DecodeError!void {
            var value = try decodeValue(records, allocator, registry);
            deinitValue(&value, allocator);
        }

        fn toJson(records: []const u8, allocator: std.mem.Allocator, json_options: json.Options) anyerror!?[]const u8 {
            var holder: Holder = .{ .value = try decodeValue(records, allocator, json_options.extensions) };
            defer protobuf.deinit(allocator, &holder);
            // Minified, the holder is `{"value":<extension value>}`, or `{}`
            // for a repeated extension without elements.
            const text = try json.encode(holder, .{}, json_options, allocator);
            defer allocator.free(text);
            const prefix = "{\"value\":";
            if (!std.mem.startsWith(u8, text, prefix)) return null;
            return try allocator.dupe(u8, text[prefix.len .. text.len - 1]);
        }

        fn fromJson(value_json: []const u8, allocator: std.mem.Allocator, parse_options: std.json.ParseOptions) anyerror![]const u8 {
            const text = try std.mem.concat(allocator, u8, &.{ "{\"value\":", value_json, "}" });
            defer allocator.free(text);
            const parsed = try std.json.parseFromSlice(Holder, allocator, text, parse_options);
            defer parsed.deinit();
            var w: std.Io.Writer.Allocating = .init(allocator);
            errdefer w.deinit();
            try protobuf.encode(&w.writer, allocator, parsed.value);
            return w.toOwnedSlice();
        }

        /// Entry of this extension in an `ExtensionRegistry`.
        pub const registry_entry: ExtensionRegistry.Entry = .{
            .extendee = @typeName(Extendee_),
            .field_number = field_number,
            .full_name = name,
            .validate = &validate,
            .to_json = &toJson,
            .from_json = &fromJson,
        };
    };
}

/// Set of known extensions, used to validate them when decoding and to
/// encode or decode them as JSON.
pub const ExtensionRegistry = struct {
    /// Sorted by extendee, then by field number, as `init` does.
    entries: []const Entry,

    pub const Entry = struct {
        /// `@typeName` of the extended message.
        extendee: []const u8,
        field_number: u29,
        full_name: []const u8,
        /// Decodes the extension from the extension records of a message.
        validate: *const fn (records: []const u8, allocator: std.mem.Allocator, registry: *const ExtensionRegistry) DecodeError!void,
        /// Returns the JSON value of the extension, which must be set, or
        /// null when it has no value to write (an empty repeated extension).
        to_json: *const fn (records: []const u8, allocator: std.mem.Allocator, options: json.Options) anyerror!?[]const u8,
        /// Returns the wire records of the extension from its JSON value.
        from_json: *const fn (value_json: []const u8, allocator: std.mem.Allocator, options: std.json.ParseOptions) anyerror![]const u8,

        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return switch (std.mem.order(u8, a.extendee, b.extendee)) {
                .lt => true,
                .gt => false,
                .eq => a.field_number < b.field_number,
            };
        }

        fn orderExtendee(extendee: []const u8, entry: Entry) std.math.Order {
            return std.mem.order(u8, extendee, entry.extendee);
        }

        fn orderFieldNumber(field_number: u29, entry: Entry) std.math.Order {
            return std.math.order(field_number, entry.field_number);
        }
    };

    /// Builds a registry from a tuple of `Extension` types, such as the
    /// `extensions` declaration of generated files:
    /// `ExtensionRegistry.init(a_pb.extensions ++ b_pb.extensions)`.
    pub fn init(comptime extensions: anytype) ExtensionRegistry {
        const entries = comptime blk: {
            var list: [extensions.len]Entry = undefined;
            for (extensions, 0..) |ext, i| list[i] = ext.registry_entry;
            @setEvalBranchQuota(1000 + 1000 * list.len * (std.math.log2_int_ceil(usize, list.len + 1) + 1));
            std.mem.sort(Entry, &list, {}, Entry.lessThan);
            break :blk list;
        };
        return .{ .entries = &entries };
    }

    /// Returns the known extensions of `Extendee`, sorted by field number.
    pub fn of(self: *const ExtensionRegistry, comptime Extendee: type) []const Entry {
        const start, const end = std.sort.equalRange(
            Entry,
            self.entries,
            @as([]const u8, @typeName(Extendee)),
            Entry.orderExtendee,
        );
        return self.entries[start..end];
    }

    /// Returns the extension `field_number` of `Extendee`, if known.
    pub fn find(self: *const ExtensionRegistry, comptime Extendee: type, field_number: u29) ?*const Entry {
        const known = self.of(Extendee);
        const index = std.sort.binarySearch(Entry, known, field_number, Entry.orderFieldNumber) orelse return null;
        return &known[index];
    }

    /// Returns the extension of `Extendee` with the given full name, if known.
    pub fn findByName(self: *const ExtensionRegistry, comptime Extendee: type, full_name: []const u8) ?*const Entry {
        for (self.of(Extendee)) |*entry| {
            if (std.mem.eql(u8, entry.full_name, full_name)) return entry;
        }
        return null;
    }

    /// Validates the known extensions of a decoded message of type `Extendee`.
    pub fn validate(self: *const ExtensionRegistry, comptime Extendee: type, records: []const u8, allocator: std.mem.Allocator) DecodeError!void {
        if (records.len == 0) return;
        const known = self.of(Extendee);
        if (known.len == 0) return;

        var fallback = std.heap.stackFallback(64, allocator);
        const bits_allocator = fallback.get();
        var present = try presentEntries(bits_allocator, known, records);
        defer present.deinit(bits_allocator);
        var it = present.iterator(.{});
        while (it.next()) |index| try known[index].validate(records, allocator, self);
    }
};

/// Returns which of the `known` extensions, sorted by field number, are set
/// in `records`. The records are only read once, whatever the number of known
/// extensions.
pub fn presentEntries(
    allocator: std.mem.Allocator,
    known: []const ExtensionRegistry.Entry,
    records: []const u8,
) (std.mem.Allocator.Error || protobuf.DecodingError || std.Io.Reader.Error)!std.DynamicBitSetUnmanaged {
    var present: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, known.len);
    errdefer present.deinit(allocator);
    var it: RecordIterator = .init(records);
    while (try it.next()) |record| {
        const index = std.sort.binarySearch(
            ExtensionRegistry.Entry,
            known,
            record.tag.field,
            ExtensionRegistry.Entry.orderFieldNumber,
        ) orelse continue;
        present.set(index);
    }
    return present;
}

/// Whether the extensions of `T` are encoded in the legacy MessageSet format.
/// Messages with extension ranges declare `_extensions_info`:
/// `.{ .ranges = .{ .{ start, end }, ... }, .message_set = bool }`, where the
/// ranges are `[start, end)`.
pub fn isMessageSet(comptime T: type) bool {
    return @hasDecl(T, "_extensions_info") and T._extensions_info.message_set;
}

/// A field (tag and value) of wire records.
pub const Record = struct {
    tag: wire.Tag,
    /// The tag and the value.
    bytes: []const u8,
    /// The value only (after the tag).
    value: []const u8,
};

/// Iterates the fields of wire records, such as `_extensions`.
pub const RecordIterator = struct {
    reader: std.Io.Reader,

    pub fn init(records: []const u8) RecordIterator {
        return .{ .reader = .fixed(records) };
    }

    pub fn next(self: *RecordIterator) (protobuf.DecodingError || std.Io.Reader.Error)!?Record {
        const start = self.reader.seek;
        if (start == self.reader.end) return null;
        const tag, _ = try wire.Tag.decode(&self.reader);
        const value_start = self.reader.seek;
        _ = try wire.skipField(&self.reader, tag);
        const all = self.reader.buffer[start..self.reader.seek];
        return .{ .tag = tag, .bytes = all, .value = self.reader.buffer[value_start..self.reader.seek] };
    }
};

/// Whether `records` contain a field `field_number`.
pub fn containsField(records: []const u8, field_number: u29) bool {
    var it: RecordIterator = .init(records);
    while (it.next() catch return false) |record| {
        if (record.tag.field == field_number) return true;
    }
    return false;
}

/// Replaces the fields `field_number` of the owned `records` by `new`.
pub fn replaceField(
    allocator: std.mem.Allocator,
    records: *[]const u8,
    field_number: u29,
    new: []const u8,
) std.mem.Allocator.Error!void {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var it: RecordIterator = .init(records.*);
    // Records are well-formed, as they were produced by the decoder or `set`.
    while (it.next() catch null) |record| {
        if (record.tag.field != field_number) try result.appendSlice(allocator, record.bytes);
    }
    try result.appendSlice(allocator, new);

    // The old records are only freed once nothing can fail anymore.
    const replaced: []const u8 = if (result.items.len > 0) try result.toOwnedSlice(allocator) else &.{};
    if (records.len > 0) allocator.free(records.*);
    records.* = replaced;
}

/// Writes extension records in MessageSet format: each length-delimited
/// record becomes an item group holding its type id and message.
pub fn writeMessageSet(writer: *std.Io.Writer, records: []const u8) std.Io.Writer.Error!void {
    var it: RecordIterator = .init(records);
    while (it.next() catch null) |record| {
        if (record.tag.wire_type != .len) {
            try writer.writeAll(record.bytes);
            continue;
        }
        _ = try (comptime wire.Tag{ .wire_type = .sgroup, .field = 1 }).encode(writer);
        _ = try (comptime wire.Tag{ .wire_type = .varint, .field = 2 }).encode(writer);
        try writeVarint(writer, record.tag.field);
        _ = try (comptime wire.Tag{ .wire_type = .len, .field = 3 }).encode(writer);
        try writer.writeAll(record.value);
        _ = try (comptime wire.Tag{ .wire_type = .egroup, .field = 1 }).encode(writer);
    }
}

fn writeVarint(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var v = value;
    while (v > 0x7F) : (v >>= 7) try writer.writeByte(0x80 | @as(u8, @truncate(v)));
    try writer.writeByte(@intCast(v));
}

/// Decodes a MessageSet item group (after its SGROUP tag) into an extension
/// record appended to `records`. Returns the number of bytes consumed.
pub fn readMessageSetItem(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    records: *std.ArrayList(u8),
) DecodeError!usize {
    var consumed: usize = 0;
    var type_id: ?u64 = null;
    var message: ?[]u8 = null;
    defer if (message) |m| allocator.free(m);

    while (true) {
        const tag, const tag_c = try wire.Tag.decode(reader);
        consumed += tag_c;
        if (tag.wire_type == .egroup) {
            if (tag.field != 1) return error.InvalidInput;
            break;
        }
        if (tag.field == 2 and tag.wire_type == .varint) {
            const id, const c = try wire.decodeScalar(.uint64, reader);
            consumed += c;
            type_id = id;
        } else if (tag.field == 3 and tag.wire_type == .len) {
            const len, const c = try wire.decodeScalar(.int32, reader);
            consumed += c;
            if (len < 0) return error.InvalidInput;
            const bytes = try reader.readAlloc(allocator, @intCast(len));
            consumed += bytes.len;
            if (message) |m| allocator.free(m);
            message = bytes;
        } else {
            consumed += try wire.skipField(reader, tag);
        }
    }

    // Items without a type id carry nothing that can be stored.
    const id = type_id orelse return consumed;
    if (id == 0 or id > std.math.maxInt(u29)) return error.InvalidInput;
    const payload = message orelse &.{};
    const tag: wire.Tag = .{ .wire_type = .len, .field = @intCast(id) };
    try records.ensureUnusedCapacity(allocator, 20 + payload.len);
    var w: std.Io.Writer = .fixed(records.unusedCapacitySlice());
    writeVarint(&w, @as(u32, @bitCast(tag))) catch unreachable;
    writeVarint(&w, payload.len) catch unreachable;
    records.items.len += w.end;
    try records.appendSlice(allocator, payload);
    return consumed;
}
