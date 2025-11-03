const std = @import("std");
const builtin = @import("builtin");

pub const PROTOC_VERSION = "32.1";

// File system utilities
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

pub fn fileExists(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

// Environment utilities
pub fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

pub fn ensureProtocBinaryDownloaded(
    b: *std.Build,
) !?[]const u8 {
    if (try getProtocBin(b)) |executable_path| {
        if (fileExists(executable_path)) {
            return executable_path;
        }

        if (!fileExists(executable_path)) {
            std.log.err("zig-protobuf: file not found: {s}", .{executable_path});
            std.process.exit(1);
        }

        return executable_path;
    }
    return null;
}

pub fn getProtocDependency(b: *std.Build) !?*std.Build.Dependency {
    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => null,
    };

    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .powerpcle, .powerpc64le => "ppcle",
        .aarch64, .aarch64_be => "aarch_64",
        .s390x => "s390",
        .x86_64 => "x86_64",
        .x86 => "x86_32",
        else => null,
    };

    const dependencyName = if (builtin.os.tag == .windows)
        try std.mem.concat(b.allocator, u8, &.{"protoc-win64"})
    else if (os != null and arch != null)
        try std.mem.concat(b.allocator, u8, &.{ "protoc-", os.?, "-", arch.? })
    else
        @panic("Platform not supported");
    defer b.allocator.free(dependencyName);

    if (b.lazyDependency(dependencyName, .{})) |dep| {
        return dep;
    }

    return null;
}

pub fn getProtocBin(b: *std.Build) !?[]const u8 {
    if (try getProtocDependency(b)) |dep| {
        if (builtin.os.tag == .windows)
            return dep.path("bin/protoc.exe").getPath(b);

        return dep.path("bin/protoc").getPath(b);
    }
    return null;
}

pub const RunProtocStep = struct {
    step: std.Build.Step,
    source_files: []const []const u8,
    include_directories: []const []const u8,
    destination_directory: std.Build.LazyPath,
    generator: *std.Build.Step.Compile,
    verbose: bool = false,

    pub const base_id = .protoc;

    pub const Options = struct {
        source_files: []const []const u8,
        include_directories: []const []const u8 = &.{},
        destination_directory: std.Build.LazyPath,
    };

    pub const StepErr = error{
        FailedToConvertProtobuf,
    };

    pub fn create(
        owner: *std.Build,
        target: std.Build.ResolvedTarget,
        options: Options,
    ) *RunProtocStep {
        var self: *RunProtocStep = owner.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .check_file,
                .name = "run protoc",
                .owner = owner,
                .makeFn = make,
            }),
            .source_files = owner.dupeStrings(options.source_files),
            .include_directories = owner.dupeStrings(options.include_directories),
            .destination_directory = options.destination_directory.dupe(owner),
            .generator = buildGenerator(owner, .{ .target = target }),
        };

        self.step.dependOn(&self.generator.step);
        return self;
    }

    pub fn createWithGenerator(
        owner: *std.Build,
        generator: *std.Build.Step.Compile,
        options: Options,
    ) *RunProtocStep {
        var self: *RunProtocStep = owner.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .check_file,
                .name = "run protoc",
                .owner = owner,
                .makeFn = make,
            }),
            .source_files = owner.dupeStrings(options.source_files),
            .include_directories = owner.dupeStrings(options.include_directories),
            .destination_directory = options.destination_directory.dupe(owner),
            .generator = generator,
        };

        self.step.dependOn(&self.generator.step);
        return self;
    }

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }

    fn make(step: *std.Build.Step, make_opt: std.Build.Step.MakeOptions) anyerror!void {
        const b = step.owner;
        const self: *RunProtocStep = @fieldParentPtr("step", step);

        const absolute_dest_dir = self.destination_directory.getPath(b);

        { // run protoc
            var argv: std.ArrayList([]const u8) = .empty;

            if (try ensureProtocBinaryDownloaded(b)) |protoc_path| {
                try argv.append(b.allocator, protoc_path);

                try argv.append(b.allocator, try std.mem.concat(
                    b.allocator,
                    u8,
                    &.{
                        "--plugin=protoc-gen-zig=",
                        self.generator.getEmittedBin().getPath(b),
                    },
                ));

                try argv.append(b.allocator, try std.mem.concat(
                    b.allocator,
                    u8,
                    &.{ "--zig_out=", absolute_dest_dir },
                ));
                if (!dirExists(absolute_dest_dir)) {
                    try std.fs.makeDirAbsolute(absolute_dest_dir);
                }

                for (self.include_directories) |it| {
                    try argv.append(
                        b.allocator,
                        try std.mem.concat(b.allocator, u8, &.{ "-I", it }),
                    );
                }
                for (self.source_files) |it| {
                    try argv.append(b.allocator, it);
                }

                if (self.verbose) {
                    std.debug.print("Running protoc:", .{});
                    for (argv.items) |it| {
                        std.debug.print(" {s}", .{it});
                    }
                    std.debug.print("\n", .{});
                }

                _ = try step.captureChildProcess(step.owner.allocator, make_opt.progress_node, argv.items);
            }

            { // run zig fmt <destination>
                argv = .empty;

                try argv.append(b.allocator, b.graph.zig_exe);
                try argv.append(b.allocator, "fmt");
                try argv.append(b.allocator, absolute_dest_dir);

                step.result_failed_command = null;

                _ = try step.captureChildProcess(step.owner.allocator, make_opt.progress_node, argv.items);
            }
        }
    }
};

pub const GenOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub fn buildGenerator(b: *std.Build, opt: GenOptions) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bootstrapped-generator/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);

    b.installArtifact(exe);

    return exe;
}
