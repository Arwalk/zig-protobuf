const std = @import("std");
const builtin = @import("builtin");

pub const PROTOC_VERSION = "36.2";

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

pub fn getProtocBin(b: *std.Build) !?std.Build.LazyPath {
    if (try getProtocDependency(b)) |dep| {
        if (builtin.os.tag == .windows)
            return dep.path("bin/protoc.exe");

        return dep.path("bin/protoc");
    }
    return null;
}

fn dupeLazyPaths(b: *std.Build, paths: []const std.Build.LazyPath) []std.Build.LazyPath {
    const array = b.allocator.alloc(std.Build.LazyPath, paths.len) catch @panic("OOM");
    for (array, paths) |*dest, source|
        dest.* = source.dupe(b.graph);
    return array;
}

pub const RunProtocStep = struct {
    step: *std.Build.Step,
    source_files: []std.Build.LazyPath,
    include_directories: []std.Build.LazyPath,
    destination_directory: std.Build.LazyPath,
    generator: *std.Build.Step.Compile,
    protoc_run: *std.Build.Step.Run,
    fmt_step: *std.Build.Step.Fmt,
    preserve_unknown_fields: bool = false,
    experimental_editions: bool = false,

    pub const base_id = .protoc;

    pub const Options = struct {
        source_files: []const std.Build.LazyPath,
        include_directories: []const std.Build.LazyPath = &.{},
        destination_directory: std.Build.LazyPath,
        /// Optional pre-built protoc-gen-zig artifact. When provided, the
        /// protoc step can be owned by a consumer builder while the generator
        /// stays owned by the zig-protobuf dependency builder.
        generator: ?*std.Build.Step.Compile = null,
        /// Optional pre-built protoc binary. When provided, overrides the
        /// built-in protoc download mechanism.
        protoc: ?std.Build.LazyPath = null,
        /// When true, every generated message preserves unknown fields during
        /// binary decode/encode round trips. Defaults to false.
        preserve_unknown_fields: bool = false,
        /// When true, accept the in-development `edition = "UNSTABLE"`, whose
        /// features may change in any protobuf release. Defaults to false.
        experimental_editions: bool = false,
    };

    pub const StepErr = error{
        FailedToConvertProtobuf,
    };

    pub fn create(
        owner: *std.Build,
        target: std.Build.ResolvedTarget,
        options: Options,
    ) *RunProtocStep {
        return createWithGenerator(
            owner,
            options.generator orelse buildGenerator(owner, .{ .target = target }),
            options,
        );
    }

    pub fn createWithGenerator(
        owner: *std.Build,
        generator: *std.Build.Step.Compile,
        options: Options,
    ) *RunProtocStep {
        // The outputs are written into the source tree, which the build cache does not
        // track. The mkdir and protoc steps must always run, otherwise a deleted file
        // would not be regenerated. The fmt step has no cache and always runs.
        const mkdir_run = makeDestinationDirectory(owner, options.destination_directory);
        mkdir_run.has_side_effects = true;
        const protoc_run = makeProtocRun(owner, generator, options);
        protoc_run.has_side_effects = true;
        protoc_run.step.dependOn(&mkdir_run.step);

        const fmt_step = owner.addFmt(.{ .paths = &.{options.destination_directory} });
        fmt_step.step.dependOn(&protoc_run.step);

        const self: *RunProtocStep = owner.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{
            .step = &fmt_step.step,
            .source_files = dupeLazyPaths(owner, options.source_files),
            .include_directories = dupeLazyPaths(owner, options.include_directories),
            .destination_directory = options.destination_directory.dupe(owner.graph),
            .generator = generator,
            .protoc_run = protoc_run,
            .fmt_step = fmt_step,
            .preserve_unknown_fields = options.preserve_unknown_fields,
            .experimental_editions = options.experimental_editions,
        };
        return self;
    }

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }

    fn makeDestinationDirectory(owner: *std.Build, destination_directory: std.Build.LazyPath) *std.Build.Step.Run {
        const run = if (builtin.os.tag == .windows) run: {
            const run = owner.addSystemCommand(&.{ "cmd", "/C", "if", "not", "exist" });
            run.addDirectoryArg(destination_directory);
            run.addArg("mkdir");
            run.addDirectoryArg(destination_directory);
            break :run run;
        } else run: {
            const run = owner.addSystemCommand(&.{ "mkdir", "-p" });
            run.addDirectoryArg(destination_directory);
            break :run run;
        };
        return run;
    }

    fn makeProtocRun(
        owner: *std.Build,
        generator: *std.Build.Step.Compile,
        options: Options,
    ) *std.Build.Step.Run {
        // The protoc binary comes from the dependency that owns the generator,
        // since a consumer builder does not declare the protoc dependencies.
        const protoc_bin = options.protoc orelse
            (getProtocBin(generator.step.owner) catch @panic("OOM"));
        const run = if (protoc_bin) |bin|
            owner.addRunFile(bin)
        else
            owner.addSystemCommand(&.{"protoc"});

        run.setName("run protoc");
        run.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", generator);

        // Generator parameters, passed as `--zig_out=a,b:dir`.
        var params: std.ArrayList([]const u8) = .empty;
        if (options.preserve_unknown_fields) params.append(owner.allocator, "preserve_unknown_fields=true") catch @panic("OOM");
        if (options.experimental_editions) {
            params.append(owner.allocator, "experimental_editions=true") catch @panic("OOM");
            run.addArg("--experimental_editions");
        }
        const zig_out_prefix = if (params.items.len > 0)
            std.mem.concat(owner.allocator, u8, &.{
                "--zig_out=",
                std.mem.join(owner.allocator, ",", params.items) catch @panic("OOM"),
                ":",
            }) catch @panic("OOM")
        else
            "--zig_out=";
        run.addPrefixedDirectoryArg(zig_out_prefix, options.destination_directory);

        for (options.include_directories) |include_directory| {
            run.addArg("-I");
            run.addDirectoryArg(include_directory);
        }
        for (options.source_files) |source_file| {
            run.addFileArg(source_file);
        }

        return run;
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

    const module = b.createModule(.{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);

    return exe;
}
