const ManagedString = @import("protobuf").ManagedString;
const tests = @import("../../generated/tests.pb.zig");
const WithStrings = tests.WithStrings;

pub fn get() WithStrings {
    return WithStrings{ .name = ManagedString.static("test_string") };
}

pub fn get_with_omitted_fields() WithStrings {
    return WithStrings{ .name = .Empty };
}
