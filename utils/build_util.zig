const std = @import("std");
const builtin = @import("builtin");

// Shared state for thread safety
pub var download_mutex = std.Thread.Mutex{};

pub const PROTOC_VERSION = "23.4";

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

pub fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
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

pub fn getGitHubBaseURLOwned(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GITHUB_BASE_URL")) |base_url| {
        std.log.info("zig-protobuf: respecting GITHUB_BASE_URL: {s}\n", .{base_url});
        return base_url;
    } else |_| {
        return allocator.dupe(u8, "https://github.com");
    }
}

// Download utilities
pub fn downloadFile(allocator: std.mem.Allocator, target_file: []const u8, url: []const u8) !void {
    std.debug.print("downloading {s}..\n", .{url});

    var child = if (isEnvVarTruthy(allocator, "CURL_INSECURE"))
        std.process.Child.init(&.{ "curl", "--insecure", "-L", "-o", target_file, url }, allocator)
    else
        std.process.Child.init(&.{ "curl", "-L", "-o", target_file, url }, allocator);
    child.cwd = sdkPath("/");
    child.stderr = std.fs.File.stderr();
    child.stdout = std.fs.File.stdout();
    _ = try child.spawnAndWait();
}

pub fn unzipFile(allocator: std.mem.Allocator, file: []const u8, target_directory: []const u8) !void {
    var child = switch (builtin.os.tag) {
        .windows => std.process.Child.init(
            &.{ "powershell", "-Command", "Expand-Archive -Force -Path", file, "-DestinationPath", target_directory },
            allocator,
        ),
        else => std.process.Child.init(
            &.{ "unzip", "-o", file, "-d", target_directory },
            allocator,
        ),
    };
    child.cwd = sdkPath("/");
    child.stderr = std.fs.File.stderr();
    child.stdout = std.fs.File.stdout();
    _ = try child.spawnAndWait();
}

pub fn ensureCanDownloadFiles(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "--version" },
        .cwd = sdkPath("/"),
    }) catch {
        std.log.err("zig-protobuf: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("zig-protobuf: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    }
}

pub fn ensureCanUnzipFiles(allocator: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{"unzip"},
                .cwd = sdkPath("/"),
            }) catch {
                std.log.err("zig-protobuf: error: 'unzip' failed. Is unzip not installed?", .{});
                std.process.exit(1);
            };
            defer {
                allocator.free(result.stderr);
                allocator.free(result.stdout);
            }
            if (result.term.Exited != 0) {
                std.log.err("zig-protobuf: error: 'unzip' failed. Is unzip not installed?", .{});
                std.process.exit(1);
            }
        },
    }
}

// Protoc utilities
pub fn getProtocInstallDir(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "PROTOC_PATH") catch null) |protoc_path| {
        std.log.info("zig-protobuf: respecting PROTOC_PATH: {s}\n", .{protoc_path});
        if (fileExists(protoc_path)) {
            const bin_dir = std.fs.path.dirname(protoc_path).?;
            const real_proto_dir = std.fs.path.dirname(bin_dir).?;
            return real_proto_dir;
        }

        std.log.err("zig-protobuf: cannot resolve a protoc provided via PROTOC_PATH env var ({s}), make sure the value is correct", .{protoc_path});
        std.process.exit(1);
    }

    const base_cache_dir_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "zig-protobuf", "protoc" });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(allocator, base_cache_dir_rel);
    const versioned_cache_dir = try std.fs.path.join(allocator, &.{ base_cache_dir, protoc_version });
    defer {
        allocator.free(base_cache_dir_rel);
        allocator.free(base_cache_dir);
        allocator.free(versioned_cache_dir);
    }

    const target_cache_dir = try std.fs.path.join(allocator, &.{ versioned_cache_dir, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return target_cache_dir;
}

pub fn ensureProtocBinaryDownloaded(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    const target_cache_dir = try getProtocInstallDir(allocator, protoc_version);

    const executable_path = if (builtin.os.tag == .windows)
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc.exe" })
    else
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc" });

    if (fileExists(executable_path)) {
        return executable_path;
    }

    downloadProtoc(allocator, target_cache_dir, protoc_version) catch |err| {
        std.log.err("zig-protobuf: download protoc failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (!fileExists(executable_path)) {
        std.log.err("zig-protobuf: file not found: {s}", .{executable_path});
        std.process.exit(1);
    }

    return executable_path;
}

pub fn getProtocDownloadLink(allocator: std.mem.Allocator, version: []const u8) !?[]const u8 {
    const github_base_url = try getGitHubBaseURLOwned(allocator);
    defer allocator.free(github_base_url);

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

    const asset = if (builtin.os.tag == .windows)
        try std.mem.concat(allocator, u8, &.{ "protoc-", version, "-win64.zip" })
    else if (os != null and arch != null)
        try std.mem.concat(allocator, u8, &.{ "protoc-", version, "-", os.?, "-", arch.?, ".zip" })
    else
        return null;
    defer allocator.free(asset);

    return try std.mem.concat(allocator, u8, &.{
        github_base_url,
        "/protocolbuffers/protobuf/releases/download/v",
        version,
        "/",
        asset,
    });
}

pub fn downloadProtoc(
    allocator: std.mem.Allocator,
    target_cache_dir: []const u8,
    protoc_version: []const u8,
) !void {
    download_mutex.lock();
    defer download_mutex.unlock();

    ensureCanDownloadFiles(allocator);
    ensureCanUnzipFiles(allocator);

    const download_dir = try std.fs.path.join(allocator, &.{ target_cache_dir, "download" });
    defer allocator.free(download_dir);
    std.fs.cwd().makePath(download_dir) catch @panic(download_dir);
    std.debug.print("download_dir: {s}\n", .{download_dir});

    const download_url = try getProtocDownloadLink(allocator, protoc_version);

    if (download_url == null) {
        std.log.err("zig-protobuf: cannot resolve a protoc version to download. make sure the architecture you are using is supported", .{});
        std.process.exit(1);
    }

    defer allocator.free(download_url.?);

    const zip_target_file = try std.fs.path.join(allocator, &.{ download_dir, "protoc.zip" });
    defer allocator.free(zip_target_file);
    downloadFile(allocator, zip_target_file, download_url.?) catch @panic(zip_target_file);

    unzipFile(allocator, zip_target_file, target_cache_dir) catch @panic(zip_target_file);

    try std.fs.deleteTreeAbsolute(download_dir);
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
        dependency_builder: *std.Build,
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
            .generator = buildGenerator(dependency_builder, .{ .target = target }),
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
        _ = make_opt;
        const b = step.owner;
        const self: *RunProtocStep = @fieldParentPtr("step", step);

        const absolute_dest_dir = self.destination_directory.getPath(b);

        { // run protoc
            var argv: std.ArrayList([]const u8) = .empty;

            const protoc_path = try ensureProtocBinaryDownloaded(b.allocator, PROTOC_VERSION);
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
