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

fn encodeToBytes(allocator: std.mem.Allocator, msg: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    try msg.encode(&w.writer, allocator);
    return w.written();
}

// Decode from protobuf binary or JSON, re-encode to the requested format.
fn doRoundTrip(
    comptime MsgType: type,
    allocator: std.mem.Allocator,
    payload_union: ConformanceRequest.payload_union,
    is_protobuf_input: bool,
    is_protobuf_output: bool,
) ConformanceResponse {
    // Emit flat oneof fields per the protobuf JSON spec.
    const pb_json_opts: protobuf.json.Options = .{ .emit_oneof_field_name = false };

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
            const json_str = msg.jsonEncode(.{}, pb_json_opts, allocator) catch
                return makeResponse(.{ .serialize_error = "Failed to encode JSON" });
            return makeResponse(.{ .json_payload = json_str });
        }
    } else {
        // JSON input
        const json_payload = payload_union.json_payload;
        const parsed = MsgType.jsonDecode(json_payload, .{ .ignore_unknown_fields = true }, allocator) catch
            return makeResponse(.{ .parse_error = "Failed to decode JSON" });
        defer parsed.deinit();
        const msg = parsed.value;

        if (is_protobuf_output) {
            const bytes = encodeToBytes(allocator, msg) catch
                return makeResponse(.{ .serialize_error = "Failed to encode protobuf" });
            return makeResponse(.{ .protobuf_payload = bytes });
        } else {
            const json_str = msg.jsonEncode(.{}, pb_json_opts, allocator) catch
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
        return doRoundTrip(TestAllTypesProto3, allocator, payload_union, is_protobuf_input, is_protobuf_output);
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
