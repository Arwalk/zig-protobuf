const std = @import("std");
const testing = std.testing;
const service = @import("generated/tests/service.pb.zig");

// Define a simple server context for testing
const TestServerContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,

    // Error types required by the service implementations
    pub const UnaryCallError = error{TestFailure};
    pub const AnotherCallError = error{TestFailure};
    pub const ServerStreamError = error{TestFailure};
    pub const ClientStreamError = error{TestFailure};
    pub const BidiStreamError = error{TestFailure};
};

test "SimpleService - UnaryCall implementation works" {
    const allocator = testing.allocator;

    // Define the implementations vtable
    const SimpleServiceImpl = service.SimpleServiceImplementations(TestServerContext);

    // Create an implementation function
    const unaryCallImpl = struct {
        fn call(context: *TestServerContext, request: service.UnaryRequest) !service.UnaryResponse {
            context.call_count += 1;
            return service.UnaryResponse{
                .result = request.message,
                .success = request.value > 0,
            };
        }
    }.call;

    const anotherCallImpl = struct {
        fn call(context: *TestServerContext, request: service.StreamRequest) !service.StreamResponse {
            context.call_count += 1;
            _ = request;
            return service.StreamResponse{ .data = "test" };
        }
    }.call;

    // Create server context
    var ctx = TestServerContext{ .allocator = allocator };

    // Create service instance
    const SimpleServiceType = service.SimpleService(TestServerContext);
    var svc = SimpleServiceType{
        .context = &ctx,
        .implementations = SimpleServiceImpl{
            .UnaryCall = unaryCallImpl,
            .AnotherCall = anotherCallImpl,
        },
    };

    // Test calling the method
    const request = service.UnaryRequest{
        .message = "hello",
        .value = 42,
    };

    const response = try svc.UnaryCall(request);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
    try testing.expectEqualStrings("hello", response.result);
    try testing.expectEqual(true, response.success);
}

test "StreamingService - ServerStream signature is correct" {
    const allocator = testing.allocator;

    const StreamingServiceImpl = service.StreamingServiceImplementations(TestServerContext);

    const serverStreamImpl = struct {
        fn call(context: *TestServerContext, request: service.StreamRequest, writer_queue: *std.Io.Queue(service.StreamResponse)) !void {
            context.call_count += 1;
            _ = request;
            _ = writer_queue;
        }
    }.call;

    const clientStreamImpl = struct {
        fn call(context: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest)) TestServerContext.ClientStreamError!service.StreamResponse {
            context.call_count += 1;
            _ = reader_queue;
            return service.StreamResponse{ .data = "result" };
        }
    }.call;

    const bidiStreamImpl = struct {
        fn call(context: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest), writer_queue: *std.Io.Queue(service.StreamResponse)) TestServerContext.BidiStreamError!void {
            context.call_count += 1;
            _ = reader_queue;
            _ = writer_queue;
        }
    }.call;

    var ctx = TestServerContext{ .allocator = allocator };

    const StreamingServiceType = service.StreamingService(TestServerContext);
    var svc = StreamingServiceType{
        .context = &ctx,
        .implementations = StreamingServiceImpl{
            .ServerStream = serverStreamImpl,
            .ClientStream = clientStreamImpl,
            .BidiStream = bidiStreamImpl,
        },
    };

    // Test server streaming with Queue
    var response_buffer: [10]service.StreamResponse = undefined;
    var writer_queue: std.Io.Queue(service.StreamResponse) = .init(&response_buffer);

    const request = service.StreamRequest{ .id = 1 };
    try svc.ServerStream(request, &writer_queue);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "StreamingService - ClientStream returns response" {
    const allocator = testing.allocator;

    const StreamingServiceImpl = service.StreamingServiceImplementations(TestServerContext);

    const serverStreamImpl = struct {
        fn call(context: *TestServerContext, request: service.StreamRequest, writer_queue: *std.Io.Queue(service.StreamResponse)) TestServerContext.ServerStreamError!void {
            _ = context;
            _ = request;
            _ = writer_queue;
        }
    }.call;

    const clientStreamImpl = struct {
        fn call(context: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest)) TestServerContext.ClientStreamError!service.StreamResponse {
            context.call_count += 1;
            _ = reader_queue;
            return service.StreamResponse{ .data = "aggregated result" };
        }
    }.call;

    const bidiStreamImpl = struct {
        fn call(context: *TestServerContext, reader_queue: *std.Io.Queue(service.StreamRequest), writer_queue: *std.Io.Queue(service.StreamResponse)) TestServerContext.BidiStreamError!void {
            _ = context;
            _ = reader_queue;
            _ = writer_queue;
        }
    }.call;

    var ctx = TestServerContext{ .allocator = allocator };

    const StreamingServiceType = service.StreamingService(TestServerContext);
    var svc = StreamingServiceType{
        .context = &ctx,
        .implementations = StreamingServiceImpl{
            .ServerStream = serverStreamImpl,
            .ClientStream = clientStreamImpl,
            .BidiStream = bidiStreamImpl,
        },
    };

    // Test client streaming with Queue
    var request_buffer: [10]service.StreamRequest = undefined;
    var reader_queue: std.Io.Queue(service.StreamRequest) = .init(&request_buffer);

    const response = try svc.ClientStream(&reader_queue);

    try testing.expectEqual(@as(usize, 1), ctx.call_count);
    try testing.expectEqualStrings("aggregated result", response.data);
}

test "Service can use different context types" {
    // Test that the same service can be instantiated with different context types

    const ContextA = struct {
        value_a: i32,

        pub const UnaryCallError = error{ContextAError};
        pub const AnotherCallError = error{ContextAError};
    };

    const ContextB = struct {
        value_b: []const u8,

        pub const UnaryCallError = error{ContextBError};
        pub const AnotherCallError = error{ContextBError};
    };

    const ServiceA = service.SimpleService(ContextA);
    const ServiceB = service.SimpleService(ContextB);

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
