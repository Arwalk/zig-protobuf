const std = @import("std");
const testing = std.testing;
const service = @import("generated/tests/service.pb.zig");

// Define a simple server context for testing
const TestServerContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
};

const TestErrorSet = error{TestFailure};

test "SimpleService - UnaryCall implementation works" {
    const allocator = testing.allocator;

    const SimpleServiceVTable = service.SimpleService(TestServerContext, TestErrorSet);

    const unaryCallImpl = struct {
        fn call(userdata: *TestServerContext, request: service.UnaryRequest) TestErrorSet!service.UnaryResponse {
            userdata.call_count += 1;
            return service.UnaryResponse{
                .result = request.message,
                .success = request.value > 0,
            };
        }
    }.call;

    const anotherCallImpl = struct {
        fn call(userdata: *TestServerContext, request: service.StreamRequest) TestErrorSet!service.StreamResponse {
            userdata.call_count += 1;
            _ = request;
            return service.StreamResponse{ .data = "test" };
        }
    }.call;

    var ctx = TestServerContext{ .allocator = allocator };

    const vtable = SimpleServiceVTable{
        .UnaryCall = unaryCallImpl,
        .AnotherCall = anotherCallImpl,
    };

    const request = service.UnaryRequest{
        .message = "hello",
        .value = 42,
    };

    const response = try vtable.UnaryCall(&ctx, request);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
    try testing.expectEqualStrings("hello", response.result);
    try testing.expectEqual(true, response.success);
}

test "StreamingService - ServerStream signature is correct" {
    const allocator = testing.allocator;

    const StreamingServiceVTable = service.StreamingService(TestServerContext, TestErrorSet);

    const serverStreamImpl = struct {
        fn call(userdata: *TestServerContext, request: service.StreamRequest, writer_queue: *std.Io.Queue(service.StreamResponse)) TestErrorSet!void {
            userdata.call_count += 1;
            _ = request;
            _ = writer_queue;
        }
    }.call;

    const clientStreamImpl = struct {
        fn call(userdata: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest)) TestErrorSet!service.StreamResponse {
            userdata.call_count += 1;
            _ = reader_queue;
            return service.StreamResponse{ .data = "result" };
        }
    }.call;

    const bidiStreamImpl = struct {
        fn call(userdata: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest), writer_queue: *std.Io.Queue(service.StreamResponse)) TestErrorSet!void {
            userdata.call_count += 1;
            _ = reader_queue;
            _ = writer_queue;
        }
    }.call;

    var ctx = TestServerContext{ .allocator = allocator };

    const vtable = StreamingServiceVTable{
        .ServerStream = serverStreamImpl,
        .ClientStream = clientStreamImpl,
        .BidiStream = bidiStreamImpl,
    };

    // Test server streaming with Queue
    var response_buffer: [10]service.StreamResponse = undefined;
    var writer_queue: std.Io.Queue(service.StreamResponse) = .init(&response_buffer);

    const request = service.StreamRequest{ .id = 1 };
    try vtable.ServerStream(&ctx, request, &writer_queue);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "StreamingService - ClientStream returns response" {
    const allocator = testing.allocator;

    const StreamingServiceVTable = service.StreamingService(TestServerContext, TestErrorSet);

    const serverStreamImpl = struct {
        fn call(userdata: *TestServerContext, request: service.StreamRequest, writer_queue: *std.Io.Queue(service.StreamResponse)) TestErrorSet!void {
            _ = userdata;
            _ = request;
            _ = writer_queue;
        }
    }.call;

    const clientStreamImpl = struct {
        fn call(userdata: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest)) TestErrorSet!service.StreamResponse {
            userdata.call_count += 1;
            _ = reader_queue;
            return service.StreamResponse{ .data = "aggregated result" };
        }
    }.call;

    const bidiStreamImpl = struct {
        fn call(userdata: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest), writer_queue: *std.Io.Queue(service.StreamResponse)) TestErrorSet!void {
            _ = userdata;
            _ = reader_queue;
            _ = writer_queue;
        }
    }.call;

    var ctx = TestServerContext{ .allocator = allocator };

    const vtable = StreamingServiceVTable{
        .ServerStream = serverStreamImpl,
        .ClientStream = clientStreamImpl,
        .BidiStream = bidiStreamImpl,
    };

    // Test client streaming with Queue
    var request_buffer: [10]service.StreamRequest = undefined;
    var reader_queue: std.Io.Queue(service.StreamRequest) = .init(&request_buffer);

    const response = try vtable.ClientStream(&ctx, &reader_queue);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
    try testing.expectEqualStrings("aggregated result", response.data);
}

test "Service can use different context types" {
    // Test that the same service can be instantiated with different context types

    const ContextA = struct { value_a: i32 };
    const ContextB = struct { value_b: []const u8 };

    const ErrorSetA = error{ContextAError};
    const ErrorSetB = error{ContextBError};

    const ServiceA = service.SimpleService(ContextA, ErrorSetA);
    const ServiceB = service.SimpleService(ContextB, ErrorSetB);

    // These should be different types
    try testing.expect(ServiceA != ServiceB);
}

test "Message types are still accessible" {
    // Verify that message types are still generated and usable
    const request = service.UnaryRequest{
        .message = "test",
        .value = 123,
    };

    const response = service.UnaryResponse{
        .result = "result",
        .success = true,
    };

    try testing.expectEqualStrings("test", request.message);
    try testing.expectEqual(@as(i32, 123), request.value);
    try testing.expectEqualStrings("result", response.result);
    try testing.expectEqual(true, response.success);
}

test "Messages can be encoded and decoded" {
    const allocator = testing.allocator;

    var request = service.UnaryRequest{
        .message = "test message",
        .value = 42,
    };

    // Encode it
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);

    // Decode it
    var reader: std.Io.Reader = .fixed(writer.written());
    var decoded = try service.UnaryRequest.decode(&reader, allocator);
    defer decoded.deinit(allocator);

    // Verify
    try testing.expectEqualStrings("test message", decoded.message);
    try testing.expectEqual(@as(i32, 42), decoded.value);
}
