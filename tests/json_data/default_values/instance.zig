const DefaultValues = @import("../../generated/jspb/test.pb.zig").DefaultValues;

pub fn get() DefaultValues {
    return DefaultValues{
        .string_field = .Empty,
        .bool_field = false,
        .int_field = 0,
        .enum_field = .E1,
        .empty_field = .Empty,
        .bytes_field = .Empty,
    };
}

pub fn get_with_omitted_fields() DefaultValues {
    return DefaultValues{};
}
