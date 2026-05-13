const std = @import("std");
const protobuf = @import("protobuf.zig");
const fd = protobuf.fd;

// Google's defined Well-Known Types with special semantics

// ─── google.protobuf.Any ────────────────────────────────────────────────────

// Resolver for google.protobuf.Any JSON serialization.
// Set this before encoding/decoding Any types to/from JSON.
pub const AnyJsonOutput = union(enum) {
    // WKT types: inner value goes under "value" key → {"@type":"...","value":<val>}
    wkt: std.json.Value,
    // Regular message: fields go directly → {"@type":"...", <fields>}
    message: std.json.ObjectMap,
};

pub const AnyJsonResolver = struct {
    // Converts a JSON object to binary protobuf bytes.
    // obj includes all fields (including "@type").
    from_json: *const fn (type_url: []const u8, obj: std.json.ObjectMap, alloc: std.mem.Allocator) anyerror![]const u8,
    // Converts binary protobuf bytes to a JSON value representation.
    to_json: *const fn (type_url: []const u8, bytes: []const u8, alloc: std.mem.Allocator) anyerror!AnyJsonOutput,
};
pub var any_json_resolver: ?AnyJsonResolver = null;
// Thread-local allocator used by Any.jsonStringify (set by json.encode).
pub threadlocal var tl_any_alloc: ?std.mem.Allocator = null;

pub const Any = struct {
    type_url: []const u8 = &.{},
    value: []const u8 = &.{},

    pub const _desc_table = .{
        .type_url = fd(1, .{ .scalar = .string }),
        .value = fd(2, .{ .scalar = .bytes }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        if (self.type_url.len == 0) {
            // Empty Any: emit as empty object {}.
            try jws.beginObject();
            try jws.endObject();
            return;
        }
        const alloc = tl_any_alloc orelse return error.WriteFailed;
        const resolver = any_json_resolver orelse return error.WriteFailed;
        const output = resolver.to_json(self.type_url, self.value, alloc) catch return error.WriteFailed;
        try jws.beginObject();
        try jws.objectField("@type");
        try jws.write(self.type_url);
        switch (output) {
            .wkt => |val| {
                try jws.objectField("value");
                try jws.write(val);
            },
            .message => |fields| {
                var iter = fields.iterator();
                while (iter.next()) |entry| {
                    try jws.objectField(entry.key_ptr.*);
                    try jws.write(entry.value_ptr.*);
                }
            },
        }
        try jws.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const parsed = try std.json.innerParse(std.json.Value, allocator, source, options);
        const obj = switch (parsed) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        // Missing @type means empty Any (valid per spec).
        const type_url_val = obj.get("@type") orelse return @This(){};
        const type_url = switch (type_url_val) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (type_url.len == 0) return error.UnexpectedToken;
        // Validate URL format: must contain at least one "/" with non-empty path after it.
        const slash_idx = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return error.UnexpectedToken;
        if (slash_idx + 1 >= type_url.len) return error.UnexpectedToken;
        const resolver = any_json_resolver orelse return error.UnexpectedToken;
        const bytes = resolver.from_json(type_url, obj, allocator) catch return error.UnexpectedToken;
        return @This(){
            .type_url = try allocator.dupe(u8, type_url),
            .value = bytes,
        };
    }
};

// ─── google.protobuf.Duration ───────────────────────────────────────────────

pub const Duration = struct {
    seconds: i64 = 0,
    nanos: i32 = 0,

    pub const _desc_table = .{
        .seconds = fd(1, .{ .scalar = .int64 }),
        .nanos = fd(2, .{ .scalar = .int32 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (str_token) {
            .allocated_string => |s| allocator.free(s),
            else => {},
        };
        const str = switch (str_token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (str.len == 0 or str[str.len - 1] != 's') return error.UnexpectedToken;
        const body = str[0 .. str.len - 1];
        const dot_pos = std.mem.indexOfScalar(u8, body, '.');
        var seconds: i64 = 0;
        var nanos: i32 = 0;
        if (dot_pos) |dp| {
            const sec_str = body[0..dp];
            const frac_str = body[dp + 1 ..];
            const negative = sec_str.len > 0 and sec_str[0] == '-';
            seconds = std.fmt.parseInt(i64, sec_str, 10) catch return error.UnexpectedToken;
            if (frac_str.len == 0 or frac_str.len > 9) return error.UnexpectedToken;
            var frac_buf: [9]u8 = [_]u8{'0'} ** 9;
            @memcpy(frac_buf[0..frac_str.len], frac_str);
            const frac_val = std.fmt.parseInt(u32, &frac_buf, 10) catch return error.UnexpectedToken;
            nanos = @intCast(frac_val);
            if (negative) nanos = -nanos;
        } else {
            seconds = std.fmt.parseInt(i64, body, 10) catch return error.UnexpectedToken;
        }
        // Proto3 JSON: duration must be in the range [-315576000000s, +315576000000s].
        if (seconds < -315576000000 or seconds > 315576000000) return error.UnexpectedToken;
        return @This(){ .seconds = seconds, .nanos = nanos };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        if (self.seconds < -315576000000 or self.seconds > 315576000000) return error.WriteFailed;
        if (self.nanos < -999999999 or self.nanos > 999999999) return error.WriteFailed;
        if (self.seconds > 0 and self.nanos < 0) return error.WriteFailed;
        if (self.seconds < 0 and self.nanos > 0) return error.WriteFailed;
        const abs_sec: u64 = @intCast(if (self.seconds < 0) -self.seconds else self.seconds);
        const abs_nano: u32 = @intCast(if (self.nanos < 0) -self.nanos else self.nanos);
        const negative = self.seconds < 0 or (self.seconds == 0 and self.nanos < 0);
        var buf: [64]u8 = undefined;
        const s = if (self.nanos == 0) blk: {
            if (negative)
                break :blk std.fmt.bufPrint(&buf, "\"-{d}s\"", .{abs_sec}) catch unreachable
            else
                break :blk std.fmt.bufPrint(&buf, "\"{d}s\"", .{abs_sec}) catch unreachable;
        } else if (@rem(abs_nano, 1_000_000) == 0) blk: {
            const millis: u32 = abs_nano / 1_000_000;
            if (negative)
                break :blk std.fmt.bufPrint(&buf, "\"-{d}.{d:0>3}s\"", .{ abs_sec, millis }) catch unreachable
            else
                break :blk std.fmt.bufPrint(&buf, "\"{d}.{d:0>3}s\"", .{ abs_sec, millis }) catch unreachable;
        } else if (@rem(abs_nano, 1_000) == 0) blk: {
            const micros: u32 = abs_nano / 1_000;
            if (negative)
                break :blk std.fmt.bufPrint(&buf, "\"-{d}.{d:0>6}s\"", .{ abs_sec, micros }) catch unreachable
            else
                break :blk std.fmt.bufPrint(&buf, "\"{d}.{d:0>6}s\"", .{ abs_sec, micros }) catch unreachable;
        } else blk: {
            if (negative)
                break :blk std.fmt.bufPrint(&buf, "\"-{d}.{d:0>9}s\"", .{ abs_sec, abs_nano }) catch unreachable
            else
                break :blk std.fmt.bufPrint(&buf, "\"{d}.{d:0>9}s\"", .{ abs_sec, abs_nano }) catch unreachable;
        };
        try jws.print("{s}", .{s});
    }
};

// ─── google.protobuf.FieldMask ──────────────────────────────────────────────

pub const FieldMask = struct {
    paths: std.ArrayList([]const u8) = .empty,

    pub const _desc_table = .{
        .paths = fd(1, .{ .repeated = .{ .scalar = .string } }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (str_token) {
            .allocated_string => |s| allocator.free(s),
            else => {},
        };
        const str = switch (str_token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        var result: @This() = .{};
        if (str.len == 0) return result;
        var it = std.mem.splitScalar(u8, str, ',');
        while (it.next()) |camel_path| {
            var snake_buf: std.ArrayList(u8) = .empty;
            defer snake_buf.deinit(allocator);
            var comp_it = std.mem.splitScalar(u8, camel_path, '.');
            var first_comp = true;
            while (comp_it.next()) |comp| {
                if (!first_comp) try snake_buf.append(allocator, '.');
                first_comp = false;
                for (comp) |c| {
                    if (c == '_') return error.UnexpectedToken; // underscores invalid in JSON FieldMask
                    if (c >= 'A' and c <= 'Z') {
                        try snake_buf.append(allocator, '_');
                        try snake_buf.append(allocator, c + 32);
                    } else {
                        try snake_buf.append(allocator, c);
                    }
                }
            }
            try result.paths.append(allocator, try snake_buf.toOwnedSlice(allocator));
        }
        return result;
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        // Validate all paths before writing. A path is invalid if it contains
        // uppercase letters, digits after underscore, consecutive underscores,
        // or trailing underscores — any of which prevent reversible snake↔camel conversion.
        for (self.paths.items) |path| {
            var comp_it = std.mem.splitScalar(u8, path, '.');
            while (comp_it.next()) |comp| {
                var prev_was_underscore = false;
                for (comp, 0..) |c, ci| {
                    if (c >= 'A' and c <= 'Z') return error.WriteFailed;
                    if (c == '_') {
                        if (prev_was_underscore) return error.WriteFailed; // consecutive __
                        if (ci == comp.len - 1) return error.WriteFailed; // trailing _
                        prev_was_underscore = true;
                    } else {
                        if (prev_was_underscore and (c >= '0' and c <= '9')) return error.WriteFailed;
                        prev_was_underscore = false;
                    }
                }
            }
        }
        try jws.beginWriteRaw();
        try jws.writer.writeAll("\"");
        for (self.paths.items, 0..) |path, pi| {
            if (pi > 0) try jws.writer.writeAll(",");
            var comp_it = std.mem.splitScalar(u8, path, '.');
            var first_comp = true;
            while (comp_it.next()) |comp| {
                if (!first_comp) try jws.writer.writeAll(".");
                first_comp = false;
                var cap_next = false;
                for (comp) |c| {
                    if (c == '_') {
                        cap_next = true;
                    } else if (cap_next) {
                        var tmp: [1]u8 = .{if (c >= 'a' and c <= 'z') c - 32 else c};
                        try jws.writer.writeAll(&tmp);
                        cap_next = false;
                    } else {
                        var tmp: [1]u8 = .{c};
                        try jws.writer.writeAll(&tmp);
                    }
                }
            }
        }
        try jws.writer.writeAll("\"");
        jws.endWriteRaw();
    }
};

// ─── google.protobuf.NullValue ──────────────────────────────────────────────

pub const NullValue = enum(i32) {
    NULL_VALUE = 0,
    _,

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        _ = self;
        try jws.write(null);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        switch (try source.peekNextTokenType()) {
            .null => {
                _ = try source.next();
                return .NULL_VALUE;
            },
            .number => {
                const n = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                defer switch (n) {
                    .allocated_number => |s| allocator.free(s),
                    else => {},
                };
                const str = switch (n) {
                    inline .number, .allocated_number => |s| s,
                    else => return error.UnexpectedToken,
                };
                const val = std.fmt.parseInt(i32, str, 10) catch return error.UnexpectedToken;
                return @enumFromInt(val);
            },
            .string => {
                const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                defer switch (tok) {
                    .allocated_string => |s| allocator.free(s),
                    else => {},
                };
                const name = switch (tok) {
                    inline .string, .allocated_string => |s| s,
                    else => return error.UnexpectedToken,
                };
                if (std.mem.eql(u8, name, "NULL_VALUE")) return .NULL_VALUE;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

// ─── google.protobuf.Struct ─────────────────────────────────────────────────

pub const Struct = struct {
    fields: std.ArrayList(Struct.FieldsEntry) = .empty,

    pub const FieldsEntry = struct {
        key: []const u8 = &.{},
        value: ?Value = null,

        pub const _desc_table = .{
            .key = fd(1, .{ .scalar = .string }),
            .value = fd(2, .submessage),
        };

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            return protobuf.deinit(allocator, self);
        }
        pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            return protobuf.dupe(@This(), self, allocator);
        }
    };

    pub const _desc_table = .{
        .fields = fd(1, .{ .repeated = .submessage }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if ((try source.peekNextTokenType()) != .object_begin) return error.UnexpectedToken;
        _ = try source.next();
        var result: @This() = .{};
        while (true) {
            const tok_type = try source.peekNextTokenType();
            if (tok_type == .object_end) {
                _ = try source.next();
                break;
            }
            const key = try std.json.innerParse([]const u8, allocator, source, options);
            const val = try std.json.innerParse(Value, allocator, source, options);
            try result.fields.append(allocator, .{ .key = key, .value = val });
        }
        return result;
    }

    pub fn jsonStringify(self: @This(), jws: anytype) error{WriteFailed}!void {
        try jws.beginObject();
        for (self.fields.items) |entry| {
            try jws.objectField(entry.key);
            if (entry.value) |v| {
                try v.jsonStringify(jws);
            } else {
                try jws.write(null);
            }
        }
        try jws.endObject();
    }
};

// ─── google.protobuf.Value ──────────────────────────────────────────────────

pub const Value = struct {
    kind: ?kind_union = null,

    pub const kind_union = union(enum) {
        null_value: NullValue,
        bool_value: bool,
        number_value: f64,
        string_value: []const u8,
        struct_value: Struct,
        list_value: ListValue,

        pub const _desc_table = .{
            .null_value = fd(1, .@"enum"),
            .bool_value = fd(4, .{ .scalar = .bool }),
            .number_value = fd(2, .{ .scalar = .double }),
            .string_value = fd(3, .{ .scalar = .string }),
            .struct_value = fd(5, .submessage),
            .list_value = fd(6, .submessage),
        };
    };

    pub const _desc_table = .{
        .kind = fd(null, .{ .oneof = kind_union }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        switch (try source.peekNextTokenType()) {
            .null => {
                _ = try source.next();
                return @This(){ .kind = .{ .null_value = .NULL_VALUE } };
            },
            .true, .false => {
                const b = try std.json.innerParse(bool, allocator, source, options);
                return @This(){ .kind = .{ .bool_value = b } };
            },
            .number => {
                const n = try std.json.innerParse(f64, allocator, source, options);
                return @This(){ .kind = .{ .number_value = n } };
            },
            .string => {
                const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const sv: []const u8 = switch (tok) {
                    inline .string, .allocated_string => |s| s,
                    else => return error.UnexpectedToken,
                };
                if (std.mem.eql(u8, sv, "NaN")) {
                    if (tok == .allocated_string) allocator.free(sv);
                    return @This(){ .kind = .{ .number_value = std.math.nan(f64) } };
                } else if (std.mem.eql(u8, sv, "Infinity")) {
                    if (tok == .allocated_string) allocator.free(sv);
                    return @This(){ .kind = .{ .number_value = std.math.inf(f64) } };
                } else if (std.mem.eql(u8, sv, "-Infinity")) {
                    if (tok == .allocated_string) allocator.free(sv);
                    return @This(){ .kind = .{ .number_value = -std.math.inf(f64) } };
                }
                const owned = if (tok == .allocated_string) sv else try allocator.dupe(u8, sv);
                return @This(){ .kind = .{ .string_value = owned } };
            },
            .object_begin => {
                const sv = try std.json.innerParse(Struct, allocator, source, options);
                return @This(){ .kind = .{ .struct_value = sv } };
            },
            .array_begin => {
                const lv = try std.json.innerParse(ListValue, allocator, source, options);
                return @This(){ .kind = .{ .list_value = lv } };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), jws: anytype) error{WriteFailed}!void {
        if (self.kind) |k| {
            switch (k) {
                .null_value => try jws.write(null),
                .number_value => |n| {
                    if (std.math.isNan(n) or std.math.isInf(n)) {
                        return error.WriteFailed;
                    }
                    try jws.write(n);
                },
                .string_value => |s| try jws.write(s),
                .bool_value => |b| try jws.write(b),
                .struct_value => |sv| try sv.jsonStringify(jws),
                .list_value => |lv| try lv.jsonStringify(jws),
            }
        } else {
            try jws.write(null);
        }
    }
};

// ─── google.protobuf.ListValue ──────────────────────────────────────────────

pub const ListValue = struct {
    values: std.ArrayList(Value) = .empty,

    pub const _desc_table = .{
        .values = fd(1, .{ .repeated = .submessage }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if ((try source.peekNextTokenType()) != .array_begin) return error.UnexpectedToken;
        _ = try source.next();
        var result: @This() = .{};
        while (true) {
            const tok_type = try source.peekNextTokenType();
            if (tok_type == .array_end) {
                _ = try source.next();
                break;
            }
            const v = try std.json.innerParse(Value, allocator, source, options);
            try result.values.append(allocator, v);
        }
        return result;
    }

    pub fn jsonStringify(self: @This(), jws: anytype) error{WriteFailed}!void {
        try jws.beginArray();
        for (self.values.items) |v| {
            try v.jsonStringify(jws);
        }
        try jws.endArray();
    }
};

// ─── google.protobuf.Timestamp ──────────────────────────────────────────────

pub const Timestamp = struct {
    seconds: i64 = 0,
    nanos: i32 = 0,

    pub const _desc_table = .{
        .seconds = fd(1, .{ .scalar = .int64 }),
        .nanos = fd(2, .{ .scalar = .int32 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (str_token) {
            .allocated_string => |s| allocator.free(s),
            else => {},
        };
        const str = switch (str_token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (str.len < 20) return error.UnexpectedToken;
        const year = std.fmt.parseInt(i64, str[0..4], 10) catch return error.UnexpectedToken;
        if (str[4] != '-') return error.UnexpectedToken;
        const month = std.fmt.parseInt(u8, str[5..7], 10) catch return error.UnexpectedToken;
        if (str[7] != '-') return error.UnexpectedToken;
        const day = std.fmt.parseInt(u8, str[8..10], 10) catch return error.UnexpectedToken;
        if (str[10] != 'T') return error.UnexpectedToken;
        const hour = std.fmt.parseInt(u8, str[11..13], 10) catch return error.UnexpectedToken;
        if (str[13] != ':') return error.UnexpectedToken;
        const minute = std.fmt.parseInt(u8, str[14..16], 10) catch return error.UnexpectedToken;
        if (str[16] != ':') return error.UnexpectedToken;
        const second = std.fmt.parseInt(u8, str[17..19], 10) catch return error.UnexpectedToken;
        var pos: usize = 19;
        var nanos: i32 = 0;
        if (pos < str.len and str[pos] == '.') {
            pos += 1;
            const frac_start = pos;
            while (pos < str.len and str[pos] >= '0' and str[pos] <= '9') pos += 1;
            const frac_len = pos - frac_start;
            if (frac_len == 0 or frac_len > 9) return error.UnexpectedToken;
            var frac_buf: [9]u8 = [_]u8{'0'} ** 9;
            @memcpy(frac_buf[0..frac_len], str[frac_start..pos]);
            nanos = @intCast(std.fmt.parseInt(u32, &frac_buf, 10) catch return error.UnexpectedToken);
        }
        var offset_secs: i64 = 0;
        if (pos >= str.len) return error.UnexpectedToken;
        if (str[pos] == 'Z') {
            pos += 1;
        } else if (str[pos] == '+' or str[pos] == '-') {
            const sign: i64 = if (str[pos] == '+') 1 else -1;
            pos += 1;
            if (pos + 5 > str.len) return error.UnexpectedToken;
            const off_h = std.fmt.parseInt(i64, str[pos .. pos + 2], 10) catch return error.UnexpectedToken;
            if (str[pos + 2] != ':') return error.UnexpectedToken;
            const off_m = std.fmt.parseInt(i64, str[pos + 3 .. pos + 5], 10) catch return error.UnexpectedToken;
            offset_secs = sign * (off_h * 3600 + off_m * 60);
            pos += 5;
        } else return error.UnexpectedToken;
        if (pos != str.len) return error.UnexpectedToken;
        const days = days_from_civil(year, month, day);
        const unix_seconds = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second) - offset_secs;
        if (unix_seconds < -62135596800 or unix_seconds > 253402300799) return error.UnexpectedToken;
        if (nanos < 0 or nanos > 999999999) return error.UnexpectedToken;
        return @This(){ .seconds = unix_seconds, .nanos = nanos };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        if (self.seconds < -62135596800 or self.seconds > 253402300799) return error.WriteFailed;
        if (self.nanos < 0 or self.nanos > 999999999) return error.WriteFailed;
        const date = civil_from_days(@divFloor(self.seconds, 86400));
        const rem = @mod(self.seconds, 86400);
        const year: u32 = @intCast(date.year);
        const hour: u32 = @intCast(@divFloor(rem, 3600));
        const minute: u32 = @intCast(@divFloor(@mod(rem, 3600), 60));
        const second: u32 = @intCast(@mod(rem, 60));
        const nanos: u32 = @intCast(self.nanos);
        var buf: [64]u8 = undefined;
        const s = if (self.nanos == 0) blk: {
            break :blk std.fmt.bufPrint(&buf, "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"", .{ year, date.month, date.day, hour, minute, second }) catch unreachable;
        } else if (@rem(nanos, 1_000_000) == 0) blk: {
            const millis: u32 = nanos / 1_000_000;
            break :blk std.fmt.bufPrint(&buf, "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\"", .{ year, date.month, date.day, hour, minute, second, millis }) catch unreachable;
        } else if (@rem(nanos, 1_000) == 0) blk: {
            const micros: u32 = nanos / 1_000;
            break :blk std.fmt.bufPrint(&buf, "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z\"", .{ year, date.month, date.day, hour, minute, second, micros }) catch unreachable;
        } else blk: {
            break :blk std.fmt.bufPrint(&buf, "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z\"", .{ year, date.month, date.day, hour, minute, second, nanos }) catch unreachable;
        };
        try jws.print("{s}", .{s});
    }

    fn civil_from_days(z: i64) struct { year: i64, month: u8, day: u8 } {
        const z2 = z + 719468;
        const era: i64 = @divFloor(z2, 146097);
        const doe: u32 = @intCast(z2 - era * 146097);
        const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        const y: i64 = @as(i64, yoe) + era * 400;
        const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
        const mp: u32 = (5 * doy + 2) / 153;
        const d: u32 = doy - (153 * mp + 2) / 5 + 1;
        const m: u32 = if (mp < 10) mp + 3 else mp - 9;
        return .{
            .year = y + @as(i64, if (m <= 2) 1 else 0),
            .month = @intCast(m),
            .day = @intCast(d),
        };
    }

    fn days_from_civil(y: i64, m: u8, d: u8) i64 {
        const y2 = y - @as(i64, if (m <= 2) 1 else 0);
        const era: i64 = @divFloor(y2, 400);
        const yoe: u32 = @intCast(y2 - era * 400);
        const doy: u32 = (153 * (@as(u32, if (m > 2) m - 3 else m + 9)) + 2) / 5 + d - 1;
        const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + @as(i64, doe) - 719468;
    }
};

// ─── google.protobuf.DoubleValue ─────────────────────────────────────────────

pub const DoubleValue = struct {
    value: f64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .double }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(f64, allocator, source, options);
        return @This(){ .value = v };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.FloatValue ──────────────────────────────────────────────

pub const FloatValue = struct {
    value: f32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .float }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(f64, allocator, source, options);
        return @This(){ .value = @floatCast(v) };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.Int64Value ──────────────────────────────────────────────

pub const Int64Value = struct {
    value: i64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .int64 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (str_token) {
            .allocated_string, .allocated_number => |s| allocator.free(s),
            else => {},
        };
        const str = switch (str_token) {
            inline .string, .allocated_string, .number, .allocated_number => |s| s,
            else => return error.UnexpectedToken,
        };
        const val = std.fmt.parseInt(i64, str, 10) catch return error.UnexpectedToken;
        return @This(){ .value = val };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try jws.write(s);
    }
};

// ─── google.protobuf.UInt64Value ─────────────────────────────────────────────

pub const UInt64Value = struct {
    value: u64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .uint64 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const str_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (str_token) {
            .allocated_string, .allocated_number => |s| allocator.free(s),
            else => {},
        };
        const str = switch (str_token) {
            inline .string, .allocated_string, .number, .allocated_number => |s| s,
            else => return error.UnexpectedToken,
        };
        const val = std.fmt.parseInt(u64, str, 10) catch return error.UnexpectedToken;
        return @This(){ .value = val };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try jws.write(s);
    }
};

// ─── google.protobuf.Int32Value ──────────────────────────────────────────────

pub const Int32Value = struct {
    value: i32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .int32 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(i32, allocator, source, options);
        return @This(){ .value = v };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.UInt32Value ─────────────────────────────────────────────

pub const UInt32Value = struct {
    value: u32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .uint32 }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(u32, allocator, source, options);
        return @This(){ .value = v };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.BoolValue ───────────────────────────────────────────────

pub const BoolValue = struct {
    value: bool = false,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .bool }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(bool, allocator, source, options);
        return @This(){ .value = v };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.StringValue ─────────────────────────────────────────────

pub const StringValue = struct {
    value: []const u8 = &.{},

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .string }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse([]const u8, allocator, source, options);
        return @This(){ .value = v };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.write(self.value);
    }
};

// ─── google.protobuf.BytesValue ──────────────────────────────────────────────

pub const BytesValue = struct {
    value: []const u8 = &.{},

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .bytes }),
    };

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const b64str = try std.json.innerParse([]u8, allocator, source, options);
        defer allocator.free(b64str);
        const bytes = protobuf.json.decodeBase64Lenient(allocator, b64str) catch return error.UnexpectedToken;
        return @This(){ .value = bytes };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) @TypeOf(jws.*).Error!void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll("\"");
        try std.base64.standard.Encoder.encodeWriter(jws.writer, self.value);
        try jws.writer.writeAll("\"");
        jws.endWriteRaw();
    }
};

// ─── google.protobuf.Empty ───────────────────────────────────────────────────

pub const Empty = struct {
    pub const _desc_table = .{};

    pub fn encode(self: @This(), writer: *std.Io.Writer, allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        return protobuf.encode(writer, allocator, self);
    }
    pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {
        return protobuf.decode(@This(), reader, allocator);
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return protobuf.deinit(allocator, self);
    }
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return protobuf.dupe(@This(), self, allocator);
    }
    pub fn jsonDecode(input: []const u8, options: std.json.ParseOptions, allocator: std.mem.Allocator) !std.json.Parsed(@This()) {
        return protobuf.json.decode(@This(), input, options, allocator);
    }
    pub fn jsonEncode(self: @This(), options: std.json.Stringify.Options, pb_options: protobuf.json.Options, allocator: std.mem.Allocator) ![]const u8 {
        return protobuf.json.encode(self, options, pb_options, allocator);
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        return protobuf.json.parse(@This(), allocator, source, options);
    }
};
