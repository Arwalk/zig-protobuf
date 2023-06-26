const std = @import("std");
const testing = std.testing;
const unittest = @import("./generated/unittest.pb.zig");

test {
    _ = @import("./oneof.zig");
    _ = @import("./mapbox.zig");
    _ = @import("./graphics.zig");
    _ = @import("./leaks.zig");
    _ = @import("./optionals.zig");
}
