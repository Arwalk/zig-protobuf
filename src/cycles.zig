//! The messages that the fields of a message hold, known at compile time from
//! their types.

const protobuf = @import("protobuf.zig");
const FieldDescriptor = protobuf.FieldDescriptor;

/// A field of a message that holds other messages, or a oneof member that
/// does.
pub const HeldMessage = struct {
    /// The type of the messages held.
    Message: type,
    /// The field, and the member when the field is a oneof.
    field: []const u8,
    member: ?[]const u8 = null,
    /// How the field or member holds them: one by value (`M` or `?M`), one
    /// through a pointer (`*M` or `?*M`), or those of a list.
    kind: enum { value, pointer, repeated },
};

/// The messages held by the fields of the message `M`: singular submessages,
/// oneof members, and elements of repeated fields (maps included). Fields
/// missing from `_desc_table`, as `_unknown_fields` or `_extensions`, hold
/// none.
pub fn heldMessages(comptime M: type) []const HeldMessage {
    comptime {
        var held: []const HeldMessage = &.{};
        for (@typeInfo(@TypeOf(M._desc_table)).@"struct".field_names) |name| {
            const desc: FieldDescriptor = @field(M._desc_table, name);
            switch (desc.ftype) {
                .submessage => held = held ++ .{heldBy(@FieldType(M, name), name, null)},
                .repeated => |r| if (r == .submessage) {
                    const Element = @typeInfo(@FieldType(@FieldType(M, name), "items")).pointer.child;
                    held = held ++ .{HeldMessage{ .Message = Element, .field = name, .kind = .repeated }};
                },
                .oneof => |OneOf| for (@typeInfo(@TypeOf(OneOf._desc_table)).@"struct".field_names) |member| {
                    const member_desc: FieldDescriptor = @field(OneOf._desc_table, member);
                    if (member_desc.ftype == .submessage) {
                        held = held ++ .{heldBy(@FieldType(OneOf, member), name, member)};
                    }
                },
                else => {},
            }
        }
        return held;
    }
}

/// The message held by a singular field or a oneof member of type `F`.
fn heldBy(comptime F: type, comptime field: []const u8, comptime member: ?[]const u8) HeldMessage {
    const Held = switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
    return .{
        .Message = MessageOf(Held),
        .field = field,
        .member = member,
        .kind = if (@typeInfo(Held) == .pointer) .pointer else .value,
    };
}

/// The message type behind a field of type `M`, `?M`, `*M` or `?*M`.
pub fn MessageOf(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| MessageOf(o.child),
        .pointer => |p| p.child,
        else => F,
    };
}
