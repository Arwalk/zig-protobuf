const Allocator = @import("std").mem.Allocator;
const OptionalFields = @import(
    "../../generated/jspb/test.pb.zig",
).OptionalFields;

pub fn get_with_omitted_fields(allocator: Allocator) OptionalFields {
    return OptionalFields.init(allocator);
}
