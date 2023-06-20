const std = @import("std");

pub const FullName = struct {
    buf: []const u8,

    const Self = @This();

    /// this function receives a []const u8 "head" and concatenates head + '.' + tail. returns the value
    pub fn append(self: Self, allocator: std.mem.Allocator, tail: []const u8) !FullName {
        return FullName{ .buf = try std.mem.concat(allocator, u8, &.{ self.buf, ".", tail }) };
    }

    /// Name returns the short name, which is the last identifier segment.
    /// A single segment FullName is the Name itself.
    pub fn name(self: Self) FullName {
        if (std.mem.lastIndexOfLinear(u8, self.buf, ".")) |i| {
            return FullName{ .buf = self.buf[i + 1 ..] };
        }
        return self;
    }

    /// Parent returns the full name with the trailing identifier removed.
    /// A single segment FullName has no parent.
    pub fn parent(self: Self) ?FullName {
        if (std.mem.lastIndexOfLinear(u8, self.buf, ".")) |i| {
            return FullName{ .buf = self.buf[0..i] };
        }
        return null;
    }

    pub fn eql(self: Self, other: FullName) bool {
        return std.mem.eql(u8, self.buf, other.buf);
    }

    pub fn eqlString(self: Self, other: []const u8) bool {
        return std.mem.eql(u8, self.buf, other);
    }
};

test {
    var initial = FullName{ .buf = "aa.bb.cc.dd.ee" };

    try std.testing.expect(initial.eql(initial));
    try std.testing.expect(initial.eqlString(initial.buf));
    try std.testing.expect(!initial.eqlString("aa"));

    try std.testing.expectEqualSlices(u8, "ee", initial.name().buf);
    try std.testing.expectEqualSlices(u8, "aa.bb.cc.dd", initial.parent().?.buf);
    try std.testing.expectEqualSlices(u8, "aa.bb.cc", initial.parent().?.parent().?.buf);
    try std.testing.expectEqualSlices(u8, "aa.bb", initial.parent().?.parent().?.parent().?.buf);
    try std.testing.expectEqualSlices(u8, "aa", initial.parent().?.parent().?.parent().?.parent().?.buf);
    try std.testing.expect(initial.parent().?.parent().?.parent().?.parent().?.parent() == null);

    var simple = FullName{ .buf = "ee" };
    try std.testing.expectEqualSlices(u8, "ee", simple.name().buf);
    try std.testing.expect(simple.parent() == null);
}
