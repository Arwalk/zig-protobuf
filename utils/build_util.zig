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
    target: ?std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
) []const u8 {
    return getProtocBin(b, target, optimize).getPath(b);
}

pub fn getProtocDependency(
    b: *std.Build,
    target: ?std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency("protobuf", .{ .target = target, .optimize = optimize });
}

pub fn getProtocArtifact(
    b: *std.Build,
    target: ?std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return getProtocDependency(b, target, optimize).artifact("protoc");
}
pub fn getProtocBin(
    b: *std.Build,
    target: ?std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
) std.Build.LazyPath {
    return getProtocArtifact(b, target, optimize).getEmittedBin();
}

pub const RunProtocStep = struct {
    step: std.Build.Step,
    root: std.Build.LazyPath,
    source_files: []const []const u8,
    base_include: std.Build.LazyPath,
    include_directories: []const []const u8,
    destination_directory: std.Build.LazyPath,
    generator: *std.Build.Step.Compile,
    verbose: bool = false,

    pub const base_id = .protoc;

    pub const Options = struct {
        root: ?std.Build.LazyPath = null,
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
        optimize: std.builtin.OptimizeMode,
        options: Options,
    ) *RunProtocStep {
        const generator = buildGenerator(owner, .{ .target = target, .optimize = optimize });
        return createWithGenerator(owner, target, optimize, generator, options);
    }

    pub fn createWithGenerator(
        owner: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
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
            .root = options.root orelse owner.path(""),
            .source_files = owner.dupeStrings(options.source_files),
            .include_directories = owner.dupeStrings(options.include_directories),
            .base_include = getProtocDependency(owner, target, optimize).artifact("libprotobuf").getEmittedIncludeTree(),
            .destination_directory = options.destination_directory.dupe(owner),
            .generator = generator,
        };

        const protoc_artifact = getProtocArtifact(owner, target, optimize);
        self.step.dependOn(&self.generator.step);
        self.step.dependOn(&protoc_artifact.step);
        return self;
    }

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }

    fn make(step: *std.Build.Step, make_opt: std.Build.Step.MakeOptions) anyerror!void {
        _ = make_opt;
        const b = step.owner;
        const self: *RunProtocStep = @fieldParentPtr("step", step);
        const protoc_artifact = getProtocArtifact(
            b,
            self.generator.root_module.resolved_target,
            self.generator.root_module.optimize,
        );

        self.step.dependOn(&self.generator.step);
        self.step.dependOn(&protoc_artifact.step);

        const absolute_dest_dir = self.destination_directory.getPath(b);

        { // run protoc
            var argv: std.ArrayList([]const u8) = .empty;

            const protoc_path = ensureProtocBinaryDownloaded(
                b,
                self.generator.root_module.resolved_target,
                self.generator.root_module.optimize,
            );

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

            try argv.append(
                b.allocator,
                try std.mem.concat(b.allocator, u8, &.{ "-I", self.base_include.getPath(b) }),
            );

            for (self.include_directories) |it| {
                try argv.append(
                    b.allocator,
                    try std.mem.concat(b.allocator, u8, &.{ "-I", self.root.path(b, it).getPath(b) }),
                );
            }
            for (self.source_files) |it| {
                try argv.append(b.allocator, self.root.path(b, it).getPath(b));
            }

            if (self.verbose) {
                std.debug.print("Running protoc:", .{});
                for (argv.items) |it| {
                    std.debug.print(" {s}", .{it});
                }
                std.debug.print("\n", .{});
            }

            _ = try step.evalChildProcess(argv.items);
        }

        { // run zig fmt <destination>
            var argv: std.ArrayList([]const u8) = .empty;

            try argv.append(b.allocator, b.graph.zig_exe);
            try argv.append(b.allocator, "fmt");
            try argv.append(b.allocator, absolute_dest_dir);

            _ = try step.evalChildProcess(argv.items);
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
