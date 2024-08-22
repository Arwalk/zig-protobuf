const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;
const LazyPath = std.Build.LazyPath;

const PROTOC_VERSION = "23.4";

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig-protobuf",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    const exe = buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const test_step = b.step("test", "Run library tests");

    const tests = [_]*std.Build.Step.Compile{
        b.addTest(.{
            .name = "protobuf",
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "tests",
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "alltypes",
            .root_source_file = b.path("tests/alltypes.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "integration",
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "fixedsizes",
            .root_source_file = b.path("tests/tests_fixedsizes.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "varints",
            .root_source_file = b.path("tests/tests_varints.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "json",
            .root_source_file = b.path("tests/tests_json.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.addTest(.{
            .name = "FullName",
            .root_source_file = b.path("bootstrapped-generator/FullName.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };

    const convertStep = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("tests/.generated"),
        .source_files = &.{"tests/protos_for_test/generated_in_ci.proto"},
        .include_directories = &.{"tests/protos_for_test"},
    });

    const convertStep2 = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("tests/generated"),
        .source_files = &.{ "tests/protos_for_test/all.proto", "tests/protos_for_test/whitespace-in-name.proto" },
        .include_directories = &.{"tests/protos_for_test"},
    });

    for (tests) |test_item| {
        test_item.root_module.addImport("protobuf", module);

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const run_main_tests = b.addRunArtifact(test_item);

        test_item.step.dependOn(&convertStep.step);
        test_item.step.dependOn(&convertStep2.step);

        test_step.dependOn(&run_main_tests.step);
    }

    const wd = try getProtocInstallDir(std.heap.page_allocator, PROTOC_VERSION);

    const bootstrap = b.step("bootstrap", "run the generator over its own sources");

    const bootstrapConversion = RunProtocStep.create(b, b, target, .{
        .destination_directory = b.path("bootstrapped-generator"),
        .source_files = &.{
            b.pathJoin(&.{ wd, "include/google/protobuf/compiler/plugin.proto" }),
            b.pathJoin(&.{ wd, "include/google/protobuf/descriptor.proto" }),
        },
        .include_directories = &.{},
    });

    bootstrap.dependOn(&bootstrapConversion.step);
}

pub const RunProtocStep = struct {
    step: Step,
    source_files: []const []const u8,
    include_directories: []const []const u8,
    destination_directory: std.Build.LazyPath,
    generator: *std.Build.Step.Compile,
    verbose: bool = false, // useful for debugging if you need to know what protoc command is sent

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
            .step = Step.init(.{
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

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }

    fn make(step: *Step, prog_node: std.Progress.Node) anyerror!void {
        _ = prog_node;
        const b = step.owner;
        const self: *RunProtocStep = @fieldParentPtr("step", step);

        const absolute_dest_dir = self.destination_directory.getPath(b);

        { // run protoc
            var argv = std.ArrayList([]const u8).init(b.allocator);

            const protoc_path = try ensureProtocBinaryDownloaded(std.heap.page_allocator, PROTOC_VERSION);
            try argv.append(protoc_path);

            // specify the path to the plugin
            try argv.append(try std.mem.concat(b.allocator, u8, &.{ "--plugin=protoc-gen-zig=", self.generator.getEmittedBin().getPath(b) }));

            // specify the destination

            try argv.append(try std.mem.concat(b.allocator, u8, &.{ "--zig_out=", absolute_dest_dir }));
            if (!dirExists(absolute_dest_dir)) {
                try std.fs.makeDirAbsolute(absolute_dest_dir);
            }

            // include directories
            for (self.include_directories) |it| {
                try argv.append(try std.mem.concat(b.allocator, u8, &.{ "-I", it }));
            }
            for (self.source_files) |it| {
                try argv.append(it);
            }

            if (self.verbose) {
                std.debug.print("Running protoc:", .{});
                for (argv.items) |it| {
                    std.debug.print(" {s}", .{it});
                }
                std.debug.print("\n", .{});
            }

            try step.evalChildProcess(argv.items);
        }

        { // run zig fmt <destination>
            var argv = std.ArrayList([]const u8).init(b.allocator);

            try argv.append(b.graph.zig_exe);
            try argv.append("fmt");
            try argv.append(absolute_dest_dir);

            try step.evalChildProcess(argv.items);
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
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("bootstrapped-generator/main.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);

    b.installArtifact(exe);

    return exe;
}

fn getGitHubBaseURLOwned(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GITHUB_BASE_URL")) |base_url| {
        std.log.info("zig-protobuf: respecting GITHUB_BASE_URL: {s}\n", .{base_url});
        return base_url;
    } else |_| {
        return allocator.dupe(u8, "https://github.com");
    }
}

var download_mutex = std.Thread.Mutex{};

fn getProtocInstallDir(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "PROTOC_PATH") catch null) |protoc_path| {
        std.log.info("zig-protobuf: respecting PROTOC_PATH: {s}\n", .{ protoc_path });
        if (fileExists(protoc_path)) {
            // user has probably provided full path to protoc binary instead of proto_dir
            // also, if these fail and user explicitly provided custom path, we probably don't want to download stuff
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

/// ensures the protoc executable exists and returns an absolute path to it
fn ensureProtocBinaryDownloaded(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    const target_cache_dir = try getProtocInstallDir(allocator, protoc_version);

    const executable_path = if (builtin.os.tag == .windows)
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc.exe" })
    else
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc" });

    if (fileExists(executable_path)) {
        return executable_path; // nothing to do, already have the binary
    }

    downloadProtoc(allocator, target_cache_dir, protoc_version) catch |err| {
        // A download failed, or extraction failed, so wipe out the directory to ensure we correctly
        // try again next time.
        // std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        std.log.err("zig-protobuf: download protoc failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (!fileExists(executable_path)) {
        std.log.err("zig-protobuf: file not found: {s}", .{executable_path});
        std.process.exit(1);
    }

    return executable_path;
}

/// Compose the download URL, e.g.:
/// https://github.com/protocolbuffers/protobuf/releases/download/v24.3/protoc-24.3-linux-aarch_64.zip
fn getProtocDownloadLink(allocator: std.mem.Allocator, version: []const u8) !?[]const u8 {
    const github_base_url = try getGitHubBaseURLOwned(allocator);
    defer allocator.free(github_base_url);

    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => null,
    };

    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .powerpcle, .powerpc64le => "ppcle",
        .aarch64, .aarch64_be, .aarch64_32 => "aarch_64",
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

fn downloadProtoc(
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

    // Replace "..." with "---" because GitHub releases has very weird restrictions on file names.
    // https://twitter.com/slimsag/status/1498025997987315713

    const download_url = try getProtocDownloadLink(allocator, protoc_version);

    if (download_url == null) {
        std.log.err("zig-protobuf: cannot resolve a protoc version to download. make sure the architecture you are using is supported", .{});
        std.process.exit(1);
    }

    defer allocator.free(download_url.?);

    // Download protoc
    const zip_target_file = try std.fs.path.join(allocator, &.{ download_dir, "protoc.zip" });
    defer allocator.free(zip_target_file);
    downloadFile(allocator, zip_target_file, download_url.?) catch @panic(zip_target_file);

    // Decompress the .zip file
    unzipFile(allocator, zip_target_file, target_cache_dir) catch @panic(zip_target_file);

    try std.fs.deleteTreeAbsolute(download_dir);
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn downloadFile(allocator: std.mem.Allocator, target_file: []const u8, url: []const u8) !void {
    std.debug.print("downloading {s}..\n", .{url});

    // Some Windows users experience `SSL certificate problem: unable to get local issuer certificate`
    // so we give them the option to disable SSL if they desire / don't want to debug the issue.
    var child = if (isEnvVarTruthy(allocator, "CURL_INSECURE"))
        std.process.Child.init(&.{ "curl", "--insecure", "-L", "-o", target_file, url }, allocator)
    else
        std.process.Child.init(&.{ "curl", "-L", "-o", target_file, url }, allocator);
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn unzipFile(allocator: std.mem.Allocator, file: []const u8, target_directory: []const u8) !void {
    std.debug.print("decompressing {s}..\n", .{file});

    var child = std.process.Child.init(
        &.{ "unzip", "-o", file, "-d", target_directory },
        allocator,
    );
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn ensureCanDownloadFiles(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "--version" },
        .cwd = sdkPath("/"),
    }) catch { // e.g. FileNotFound
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

fn ensureCanUnzipFiles(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"unzip"},
        .cwd = sdkPath("/"),
    }) catch { // e.g. FileNotFound
        std.log.err("zig-protobuf: error: 'unzip' failed. Is curl not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("zig-protobuf: error: 'unzip' failed. Is curl not installed?", .{});
        std.process.exit(1);
    }
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}
