# Service Code Generation

zig-protobuf generates code for Protocol Buffer `service` definitions using a VTable (virtual table) pattern. This provides a flexible, type-safe interface for implementing gRPC-compatible services with custom user data types and error sets.

**Note**: This generates service interfaces only. It does not include a gRPC transport layer - users must implement their own server logic and transport.

## Generated Service Structure

For a protobuf service definition:

```protobuf
syntax = "proto3";
package example;

message Request {
  string query = 1;
}

message Response {
  string result = 1;
}

service MyService {
  // Unary RPC
  rpc UnaryCall(Request) returns (Response) {}

  // Server streaming RPC
  rpc ServerStream(Request) returns (stream Response) {}
}
```

The generator produces **one function per service** that returns a VTable struct type:

```zig
pub fn MyService(comptime UserDataType: type, comptime ErrorSet: type) type {
    return struct {
        pub const service_name = "MyService";

        UnaryCall: *const fn(userdata: *UserDataType, request: Request) ErrorSet!Response,
        ServerStream: *const fn(userdata: *UserDataType, request: Request, writer_queue: *std.Io.Queue(Response)) ErrorSet!void,
    };
}
```

The generated service is a struct type containing:
- `service_name` - Constant string with the service name
- Function pointer fields for each RPC method with appropriate signatures

## Implementing a Service

To implement and use a generated service:

1. Define your user data type (server context)

```zig
const service = @import("example.pb.zig");
const std = @import("std");

const MyUserData = struct {
    allocator: std.mem.Allocator,
    connection_id: u64,
    // Add any server state you need
};
```

2. Define your error set

```zig
const MyErrors = error{
    InvalidRequest,
    ServiceUnavailable,
};
```

3. Create the VTable type and implement the service methods

```zig
const MyServiceVTable = service.MyService(MyUserData, MyErrors);

const unaryCallImpl = struct {
    fn call(userdata: *MyUserData, request: service.Request) MyErrors!service.Response {
        // Your implementation here
        std.debug.print("Processing request from connection {}: {s}\n", .{
            userdata.connection_id,
            request.query,
        });

        return service.Response{
            .result = try std.fmt.allocPrint(
                userdata.allocator,
                "Processed: {s}",
                .{request.query},
            ),
        };
    }
}.call;

const serverStreamImpl = struct {
    fn call(userdata: *MyUserData, request: service.Request, writer_queue: *std.Io.Queue(service.Response)) MyErrors!void {
        // Stream multiple responses
        for (0..5) |i| {
            const response = service.Response{
                .result = try std.fmt.allocPrint(
                    userdata.allocator,
                    "Stream item {}: {s}",
                    .{i, request.query},
                ),
            };

            // Write response to queue
            try writer_queue.write(response);
        }
    }
}.call;
```

5. Create the VTable instance

```zig
const myServiceVTable = MyServiceVTable{
    .UnaryCall = unaryCallImpl,
    .ServerStream = serverStreamImpl,
};
```

6. Use the service

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create user data
    var userdata = MyUserData{
        .allocator = allocator,
        .connection_id = 12345,
    };

    // Call a method
    const request = service.Request{ .query = "hello" };
    const response = try myServiceVTable.UnaryCall(&userdata, request);
    defer response.deinit(allocator);

    std.debug.print("Response: {s}\n", .{response.result});
}
```

## Streaming Patterns

The generator supports all four gRPC patterns with different function signatures:

| Pattern                  | Signature                                                                                                           |
|--------------------------|---------------------------------------------------------------------------------------------------------------------|
| **Unary**                | `fn(userdata: *UserDataType, request: Request) ErrorSet!Response`                                                   |
| **Server streaming**     | `fn(userdata: *UserDataType, request: Request, writer_queue: *std.Io.Queue(Response)) ErrorSet!void`                |
| **Client streaming**     | `fn(userdata: *UserDataType, reader_queue: *std.Io.Queue(Request)) ErrorSet!Response`                               |
| **Bidirectional stream** | `fn(userdata: *UserDataType, reader_queue: *std.Io.Queue(Request), writer_queue: *std.Io.Queue(Response)) ErrorSet!void` |

### Streaming with std.Io.Queue

For streaming RPCs, the generator uses `std.Io.Queue(T)` for reading and writing messages:

- **Reader queue** (`*std.Io.Queue(Request)`): Read incoming messages from client
- **Writer queue** (`*std.Io.Queue(Response)`): Write outgoing messages to client

Example server streaming implementation:

```zig
fn serverStreamImpl(
    userdata: *MyUserData,
    request: service.Request,
    writer_queue: *std.Io.Queue(service.Response)
) MyErrors!void {
    // Generate and send multiple responses
    for (0..10) |i| {
        const response = service.Response{
            .result = try std.fmt.allocPrint(
                userdata.allocator,
                "Item {}: {s}",
                .{i, request.query},
            ),
        };
        try writer_queue.write(response);
    }
}
```

Example client streaming implementation:

```zig
fn clientStreamImpl(
    userdata: *MyUserData,
    reader_queue: *std.Io.Queue(service.Request)
) MyErrors!service.Response {
    var count: usize = 0;

    // Read all incoming requests
    while (try reader_queue.read()) |request| {
        count += 1;
        // Process request...
    }

    // Return single response
    return service.Response{
        .result = try std.fmt.allocPrint(
            userdata.allocator,
            "Processed {} requests",
            .{count},
        ),
    };
}
```

## Multiple Implementations

The same service definition can be instantiated with different user data types and error sets:

```zig
// Production implementation
const ProdUserData = struct {
    database: *Database,
    logger: *Logger,
};
const ProdErrors = error{DatabaseError, AuthError};
const ProdVTable = service.MyService(ProdUserData, ProdErrors);

const prodService = ProdVTable{
    .UnaryCall = prodUnaryCallImpl,
    .ServerStream = prodServerStreamImpl,
};

// Test implementation with mock data
const TestUserData = struct {
    test_data: []const TestRecord,
};
const TestErrors = error{TestFailure};
const TestVTable = service.MyService(TestUserData, TestErrors);

const testService = TestVTable{
    .UnaryCall = testUnaryCallImpl,
    .ServerStream = testServerStreamImpl,
};
```

## VTable Pattern Benefits

The VTable pattern offers several advantages:

1. **Type Safety**: User data type and error set are compile-time parameters, providing full type checking
2. **Flexibility**: Each service instance can use different data types and error sets
3. **Zero Runtime Overhead**: All polymorphism is resolved at compile time
4. **Testability**: Easy to create mock implementations for testing
5. **Composability**: VTables can be wrapped or composed for middleware patterns

## Example: Authentication Middleware

You can wrap VTables to add cross-cutting concerns like authentication:

```zig
fn withAuth(
    comptime VTable: type,
    impl: VTable,
    auth_token: []const u8,
) VTable {
    return .{
        .UnaryCall = struct {
            fn call(userdata: anytype, request: anytype) anyerror!@TypeOf(request) {
                // Check authentication
                if (!isValidToken(auth_token)) {
                    return error.Unauthorized;
                }
                // Call original implementation
                return impl.UnaryCall(userdata, request);
            }
        }.call,
        // Wrap other methods similarly...
    };
}
```
