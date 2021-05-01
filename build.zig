const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-protobuf", "src/protobuf.zig");
    lib.setBuildMode(mode);
    lib.install();

    var unit_tests = b.addTest("src/protobuf.zig");
    unit_tests.setBuildMode(mode);

    var functional_tests = b.addTest("tests.zig");
    functional_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&unit_tests.step);
    test_step.dependOn(&functional_tests.step);
}
