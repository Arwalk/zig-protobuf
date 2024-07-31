const tests = @import("../../generated/tests.pb.zig");
const WithSubmessages = tests.WithSubmessages;
const WithEnum = tests.WithEnum;

pub fn get() WithSubmessages {
    return WithSubmessages{ .with_enum = WithEnum{ .value = .A } };
}
