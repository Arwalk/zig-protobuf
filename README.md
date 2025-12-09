# zig-protobuf

<img src="logo.svg" width="50%">


## State of the implementation

This repository, so far, only aims at implementing [protocol buffers version 3](https://developers.google.com/protocol-buffers/docs/proto3#simple).

This project is mature enough to be used in production.

json encoding/decoding is considered a beta feature.

## Branches

There are 2 branches you can use for your development.

* `master` is the branch with current developments, working with the latest stable release of zig.
* `zig-master` is a branch that merges the developments in master, but works with the latest-ish master version of zig. 

## How to use

1. Add `protobuf` to your `build.zig.zon`.  
    ```sh
    zig fetch --save "git+https://github.com/Arwalk/zig-protobuf#master"
    ```
1. Use the `protobuf` module. In your `build.zig`'s build function, add the dependency as module before
`b.installArtifact(exe)`.
    ```zig
    pub fn build(b: *std.Build) !void {
        // first create a build for the dependency
        const protobuf_dep = b.dependency("protobuf", .{
            .target = target,
            .optimize = optimize,
        });

        // and lastly use the dependency as a module
        exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
    }
    ```

## Generating .zig files out of .proto definitions

You can do this programatically as a compilation step for your application. The following snippet shows how to create a `zig build gen-proto` command for your project.

```zig
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    // first create a build for the dependency
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });
    
    ...

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            "protocol/all.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);
}
```

## Service Code Generation

zig-protobuf generates code for Protocol Buffer `service` definitions using the delegate pattern. This provides a flexible, type-safe interface for implementing gRPC-compatible services with custom server contexts and I/O types.

**Note**: This generates service interfaces only. It does not include a gRPC transport layer - users must implement their own server logic and transport.

### Generated Service Structure

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

The generator produces two functions per service:

1. **`MyServiceImplementations(ServerContext)`** - Returns a struct with function pointers
2. **`MyService(ServerContext)`** - Returns a service struct with wrapper methods to dispatch to the function pointers

Generated code:

```zig
pub fn MyServiceImplementations(comptime ServerContext: type) type {
    return struct {
        UnaryCall: *const fn(context: *ServerContext, request: Request) anyerror!Response,
        ServerStream: *const fn(context: *ServerContext, request: Request, writer: *std.Io.Writer) anyerror!void,
    };
}

pub fn MyService(comptime ServerContext: type) type {
    return struct {
        context: *ServerContext,
        implementations: MyServiceImplementations(ServerContext),

        pub fn UnaryCall(self: @This(), request: Request) anyerror!Response {
            return self.implementations.UnaryCall(self.context, request);
        }

        pub fn ServerStream(self: @This(), request: Request, writer: *std.Io.Writer) anyerror!void {
            return self.implementations.ServerStream(self.context, request, writer);
        }
    };
}
```

### Implementing a Service

To implement and using a generated service:

```zig
const service = @import("example.pb.zig");
const std = @import("std");

// 1. Define your server context
const MyServerContext = struct {
    allocator: std.mem.Allocator,
    connection_id: u64,
    // Add any server state you need
};

// 2. Create the the service implementation
const MyServiceImpl = service.MyServiceImplementations(MyServerContext){
    .UnaryCall = struct {
        fn call(context: *MyServerContext, request: service.Request) anyerror!service.Response {
            // Your implementation here
            std.debug.print("Processing request from connection {}: {s}\n", .{
                context.connection_id,
                request.query,
            });

            return service.Response{
                .result = try std.fmt.allocPrint(
                    context.allocator,
                    "Processed: {s}",
                    .{request.query},
                ),
            };
        }
    }.call,

    .ServerStream = struct {
        fn call(context: *MyServerContext, request: service.Request, writer: *std.Io.Writer) anyerror!void {
            // Stream multiple responses
            for (0..5) |i| {
                const response = service.Response{
                    .result = try std.fmt.allocPrint(
                        context.allocator,
                        "Stream item {}: {}",
                        .{i, request.query},
                    ),
                };

                // Encode and write response
                try response.encode(writer, context.allocator);
            }
        }
    }.call,
};

// 3. Create and use the service
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server context
    var ctx = MyServerContext{
        .allocator = allocator,
        .connection_id = 12345,
    };

    // Create service instance
    const MyServiceType = service.MyService(MyServerContext);
    const svc = MyServiceType{
        .context = &ctx,
        .implementations = MyServiceImpl,
    };

    // Call a method
    const request = service.Request{ .query = "hello" };
    const response = try svc.UnaryCall(request);
    defer response.deinit(allocator);

    std.debug.print("Response: {s}\n", .{response.result});
}
```

### Streaming Patterns

The generator supports all four gRPC patterns with different function signatures:

| Pattern                  | Signature                                                                                    |
|--------------------------|----------------------------------------------------------------------------------------------|
| **Unary**                | `fn(ctx: *ServerContext, request: Request) anyerror!Response`                               |
| **Server streaming**     | `fn(ctx: *ServerContext, request: Request, writer: *std.Io.Writer) anyerror!void`           |
| **Client streaming**     | `fn(ctx: *ServerContext, reader: *std.Io.Reader) anyerror!Response`                         |
| **Bidirectional stream** | `fn(ctx: *ServerContext, reader: *std.Io.Reader, writer: *std.Io.Writer) anyerror!void`     |

### More Usage Examples

**Multiple implementations**:
```zig
// Production implementation
const ProdImpl = service.MyServiceImplementations(ProdContext){ ... };

// Test implementation
const TestImpl = service.MyServiceImplementations(TestContext){ ... };
```

**Middleware pattern**:
```zig
fn withLogging(comptime Impl: type) type {
    return struct {
        inner: Impl,

        pub fn UnaryCall(context: *ServerContext, request: Request) anyerror!Response {
            std.debug.print("Calling UnaryCall\n", .{});
            const result = try @field(Impl, "UnaryCall")(context, request);
            std.debug.print("UnaryCall completed\n", .{});
            return result;
        }
    };
}
```

-------

The zig-protobuf logo is licensed under the Attribution 4.0 International (CC BY 4.0).

The logo is inspired by the [official mascots](https://github.com/ziglang/logo?tab=readme-ov-file#official-mascots) of the Zig programming language, themselves licensed under the Attribution 4.0 International (CC BY 4.0)

Original art by vivisector.

-------

If you're really bored, you can buy me a coffee here.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N7VMS4F)
