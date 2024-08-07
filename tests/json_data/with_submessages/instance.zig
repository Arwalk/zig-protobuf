const tests = @import("../../generated/tests.pb.zig");
const WithSubmessages = tests.WithSubmessages;
const WithEnum = tests.WithEnum;

pub fn get() WithSubmessages {
    return WithSubmessages{ .with_enum = WithEnum{ .value = .A } };
}

pub fn get_with_omitted_fields() WithSubmessages {
    return WithSubmessages{ .with_enum = null };
}

pub fn get_with_omitted_enum_field() WithSubmessages {
    return WithSubmessages{ .with_enum = WithEnum{} };
}
