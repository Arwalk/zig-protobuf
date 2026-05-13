//! Conformance test harness for zig-protobuf.
//!
//! Implements the conformance testing protocol defined in conformance.proto.
//! Reads ConformanceRequest messages from stdin and writes ConformanceResponse
//! messages to stdout using the length-prefixed wire protocol.
//!
//! Usage:
//!   Build with `zig build conformance`, then run with the conformance_test_runner:
//!   conformance_test_runner --enforce_recommended ./zig-out/bin/conformance-testee
//!
//! The conformance_test_runner binary can be obtained by building the protobuf
//! project from source: https://github.com/protocolbuffers/protobuf

const std = @import("std");
const protobuf = @import("protobuf");

const conformance_pb = @import("generated/conformance.pb.zig");
const ConformanceRequest = conformance_pb.ConformanceRequest;
const ConformanceResponse = conformance_pb.ConformanceResponse;
const FailureSet = conformance_pb.FailureSet;

const proto3_pb = @import("generated/protobuf_test_messages/proto3.pb.zig");
const TestAllTypesProto3 = proto3_pb.TestAllTypesProto3;

const wkt = protobuf.wkt;
const pb_json_opts_flat: protobuf.json.Options = .{ .emit_oneof_field_name = false };

fn encodeToBytes(allocator: std.mem.Allocator, msg: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    try msg.encode(&w.writer, allocator);
    return w.written();
}

// Returns the type name (last segment after the final '/') from a type URL.
fn typeUrlName(type_url: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return type_url;
    return type_url[idx + 1 ..];
}

// Stringify a std.json.Value to a JSON bytes slice (caller owns).
fn jsonValueToBytes(alloc: std.mem.Allocator, val: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, val, .{});
}

// Parse JSON bytes to a std.json.Value (arena-allocated, no dealloc needed).
fn jsonBytesToValue(alloc: std.mem.Allocator, json: []const u8) !std.json.Value {
    const result = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    return result;
}

// Parse the JSON for a WKT: extract the "value" field and decode the WKT from its JSON.
fn parseWktFromValue(comptime T: type, obj: std.json.ObjectMap, alloc: std.mem.Allocator) ![]const u8 {
    const val = obj.get("value") orelse return error.MissingField;
    const val_json = try jsonValueToBytes(alloc, val);
    const parsed = try T.jsonDecode(val_json, .{}, alloc);
    defer parsed.deinit();
    return try encodeToBytes(alloc, parsed.value);
}

// Encode a WKT to its JSON value, wrapped as AnyJsonOutput.wkt.
fn wktToJsonOutput(msg: anytype, alloc: std.mem.Allocator) !wkt.AnyJsonOutput {
    const json_str = try wkt_jsonEncode(msg, alloc);
    const val = try jsonBytesToValue(alloc, json_str);
    return .{ .wkt = val };
}

fn wkt_jsonEncode(msg: anytype, alloc: std.mem.Allocator) ![]const u8 {
    return msg.jsonEncode(.{}, .{}, alloc);
}

// AnyJsonResolver.from_json: JSON object → binary protobuf bytes.
fn anyFromJson(type_url: []const u8, obj: std.json.ObjectMap, alloc: std.mem.Allocator) anyerror![]const u8 {
    const name = typeUrlName(type_url);

    if (std.mem.eql(u8, name, "protobuf_test_messages.proto3.TestAllTypesProto3")) {
        // Build JSON object from obj fields, excluding "@type".
        var writer: std.Io.Writer.Allocating = .init(alloc);
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try s.beginObject();
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "@type")) continue;
            try s.objectField(entry.key_ptr.*);
            try s.write(entry.value_ptr.*);
        }
        try s.endObject();
        const json_str = writer.written();
        const parsed = try TestAllTypesProto3.jsonDecode(json_str, .{}, alloc);
        defer parsed.deinit();
        return try encodeToBytes(alloc, parsed.value);
    }

    if (std.mem.eql(u8, name, "google.protobuf.Duration"))
        return parseWktFromValue(wkt.Duration, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.Timestamp"))
        return parseWktFromValue(wkt.Timestamp, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.FieldMask"))
        return parseWktFromValue(wkt.FieldMask, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.Int32Value"))
        return parseWktFromValue(wkt.Int32Value, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.Int64Value"))
        return parseWktFromValue(wkt.Int64Value, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.UInt32Value"))
        return parseWktFromValue(wkt.UInt32Value, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.UInt64Value"))
        return parseWktFromValue(wkt.UInt64Value, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.FloatValue"))
        return parseWktFromValue(wkt.FloatValue, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.DoubleValue"))
        return parseWktFromValue(wkt.DoubleValue, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.BoolValue"))
        return parseWktFromValue(wkt.BoolValue, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.StringValue"))
        return parseWktFromValue(wkt.StringValue, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.BytesValue"))
        return parseWktFromValue(wkt.BytesValue, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.Struct"))
        return parseWktFromValue(wkt.Struct, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.Value"))
        return parseWktFromValue(wkt.Value, obj, alloc);
    if (std.mem.eql(u8, name, "google.protobuf.ListValue"))
        return parseWktFromValue(wkt.ListValue, obj, alloc);

    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
        // value field holds the nested Any JSON object.
        const val = obj.get("value") orelse return error.MissingField;
        const val_json = try jsonValueToBytes(alloc, val);
        const parsed = try wkt.Any.jsonDecode(val_json, .{}, alloc);
        defer parsed.deinit();
        return try encodeToBytes(alloc, parsed.value);
    }

    return error.UnknownType;
}

// AnyJsonResolver.to_json: binary protobuf bytes → AnyJsonOutput.
fn anyToJson(type_url: []const u8, bytes: []const u8, alloc: std.mem.Allocator) anyerror!wkt.AnyJsonOutput {
    const name = typeUrlName(type_url);
    var reader: std.Io.Reader = .fixed(bytes);

    if (std.mem.eql(u8, name, "protobuf_test_messages.proto3.TestAllTypesProto3")) {
        var msg = try TestAllTypesProto3.decode(&reader, alloc);
        defer msg.deinit(alloc);
        const json_str = try msg.jsonEncode(.{}, pb_json_opts_flat, alloc);
        const val = try jsonBytesToValue(alloc, json_str);
        return .{ .message = val.object };
    }

    if (std.mem.eql(u8, name, "google.protobuf.Duration")) {
        var msg = try wkt.Duration.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Timestamp")) {
        var msg = try wkt.Timestamp.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.FieldMask")) {
        var msg = try wkt.FieldMask.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Int32Value")) {
        var msg = try wkt.Int32Value.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Int64Value")) {
        var msg = try wkt.Int64Value.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.UInt32Value")) {
        var msg = try wkt.UInt32Value.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.UInt64Value")) {
        var msg = try wkt.UInt64Value.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.FloatValue")) {
        var msg = try wkt.FloatValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.DoubleValue")) {
        var msg = try wkt.DoubleValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.BoolValue")) {
        var msg = try wkt.BoolValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.StringValue")) {
        var msg = try wkt.StringValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.BytesValue")) {
        var msg = try wkt.BytesValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Struct")) {
        var msg = try wkt.Struct.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Value")) {
        var msg = try wkt.Value.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.ListValue")) {
        var msg = try wkt.ListValue.decode(&reader, alloc);
        defer msg.deinit(alloc);
        return wktToJsonOutput(msg, alloc);
    }
    if (std.mem.eql(u8, name, "google.protobuf.Any")) {
        var msg = try wkt.Any.decode(&reader, alloc);
        defer msg.deinit(alloc);
        // Encode the nested Any to JSON (uses the resolver recursively).
        const json_str = try msg.jsonEncode(.{}, .{}, alloc);
        const val = try jsonBytesToValue(alloc, json_str);
        return .{ .wkt = val };
    }

    return error.UnknownType;
}

// Decode from protobuf binary or JSON, re-encode to the requested format.
fn doRoundTrip(
    comptime MsgType: type,
    allocator: std.mem.Allocator,
    payload_union: ConformanceRequest.payload_union,
    is_protobuf_input: bool,
    is_protobuf_output: bool,
    test_category: conformance_pb.TestCategory,
) ConformanceResponse {

    if (is_protobuf_input) {
        const payload = payload_union.protobuf_payload;
        var reader: std.Io.Reader = .fixed(payload);
        var msg = MsgType.decode(&reader, allocator) catch
            return makeResponse(.{ .parse_error = "Failed to decode protobuf" });
        defer msg.deinit(allocator);

        if (is_protobuf_output) {
            const bytes = encodeToBytes(allocator, msg) catch
                return makeResponse(.{ .serialize_error = "Failed to encode protobuf" });
            return makeResponse(.{ .protobuf_payload = bytes });
        } else {
            const json_str = msg.jsonEncode(.{}, pb_json_opts_flat, allocator) catch
                return makeResponse(.{ .serialize_error = "Failed to encode JSON" });
            return makeResponse(.{ .json_payload = json_str });
        }
    } else {
        // JSON input
        const json_payload = payload_union.json_payload;
        const json_opts = std.json.ParseOptions{
            .ignore_unknown_fields = test_category == .JSON_IGNORE_UNKNOWN_PARSING_TEST,
        };
        const parsed = MsgType.jsonDecode(json_payload, json_opts, allocator) catch {
            return makeResponse(.{ .parse_error = "Failed to decode JSON" });
        };
        defer parsed.deinit();
        const msg = parsed.value;

        if (is_protobuf_output) {
            const bytes = encodeToBytes(allocator, msg) catch
                return makeResponse(.{ .serialize_error = "Failed to encode protobuf" });
            return makeResponse(.{ .protobuf_payload = bytes });
        } else {
            const json_str = msg.jsonEncode(.{}, pb_json_opts_flat, allocator) catch
                return makeResponse(.{ .serialize_error = "Failed to encode JSON" });
            return makeResponse(.{ .json_payload = json_str });
        }
    }
}

fn runTest(allocator: std.mem.Allocator, req: ConformanceRequest) ConformanceResponse {
    // The runner sends a FailureSet request first to discover expected failures.
    // Return an empty FailureSet (no expected failures).
    if (std.mem.eql(u8, req.message_type, "conformance.FailureSet")) {
        const fs = FailureSet{};
        const bytes = encodeToBytes(allocator, fs) catch
            return makeResponse(.{ .runtime_error = "Failed to encode FailureSet" });
        return makeResponse(.{ .protobuf_payload = bytes });
    }

    const payload_union = req.payload orelse
        return makeResponse(.{ .runtime_error = "No payload in request" });

    const is_protobuf_input = payload_union == .protobuf_payload;
    const is_json_input = payload_union == .json_payload;

    if (!is_protobuf_input and !is_json_input) {
        return makeResponse(.{ .skipped = "Unsupported input format (JSPB/text)" });
    }

    const is_protobuf_output = req.requested_output_format == .PROTOBUF or
        req.requested_output_format == .UNSPECIFIED;
    const is_json_output = req.requested_output_format == .JSON;

    if (!is_protobuf_output and !is_json_output) {
        return makeResponse(.{ .skipped = "Unsupported output format (JSPB/text)" });
    }

    if (std.mem.eql(u8, req.message_type, "protobuf_test_messages.proto3.TestAllTypesProto3")) {
        return doRoundTrip(TestAllTypesProto3, allocator, payload_union, is_protobuf_input, is_protobuf_output, req.test_category);
    }

    return makeResponse(.{ .skipped = "Unsupported message type" });
}

fn makeResponse(result: ConformanceResponse.result_union) ConformanceResponse {
    return .{ .result = result };
}

fn writeResponseBytes(io: std.Io, response_bytes: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var out_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &out_len_buf, @intCast(response_bytes.len), .little);
    try std.Io.File.writeStreamingAll(stdout, io, &out_len_buf);
    try std.Io.File.writeStreamingAll(stdout, io, response_bytes);
}

// Returns false on EOF (normal shutdown), true to continue.
fn serveConformanceRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdin_reader: *std.Io.Reader,
) !bool {
    // Use a per-request arena so all request/response memory is freed together.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read 4-byte little-endian length prefix.
    const len_bytes_ptr = stdin_reader.takeArray(4) catch |err| {
        if (err == error.EndOfStream) return false;
        return err;
    };
    const len_bytes = len_bytes_ptr.*;
    const in_len = std.mem.readInt(u32, &len_bytes, .little);
    if (in_len == 0) return false;

    // Read request bytes into arena.
    var request_list: std.ArrayList(u8) = .empty;
    try stdin_reader.appendExact(allocator, &request_list, in_len);
    const request_data = request_list.items;

    // Decode ConformanceRequest.
    var pb_reader: std.Io.Reader = .fixed(request_data);
    var request = ConformanceRequest.decode(&pb_reader, allocator) catch {
        const resp = makeResponse(.{ .runtime_error = "Failed to parse ConformanceRequest" });
        var w: std.Io.Writer.Allocating = .init(allocator);
        resp.encode(&w.writer, allocator) catch {};
        try writeResponseBytes(io, w.written());
        return true;
    };
    defer request.deinit(allocator);

    // Process and send response.
    const response = runTest(allocator, request);
    var w: std.Io.Writer.Allocating = .init(allocator);
    response.encode(&w.writer, allocator) catch {
        try writeResponseBytes(io, &.{});
        return true;
    };
    try writeResponseBytes(io, w.written());
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Install the Any JSON resolver for google.protobuf.Any support.
    protobuf.wkt.any_json_resolver = .{
        .from_json = &anyFromJson,
        .to_json = &anyToJson,
    };

    var stdin_buf: [65536]u8 = undefined;
    var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

    var total_runs: usize = 0;
    while (true) {
        const should_continue = serveConformanceRequest(gpa, io, &stdin_file_reader.interface) catch |err| {
            std.log.err("Error serving conformance request: {}", .{err});
            return err;
        };
        if (!should_continue) break;
        total_runs += 1;
    }

    std.log.info("conformance-zig-protobuf: served {} tests", .{total_runs});
}
