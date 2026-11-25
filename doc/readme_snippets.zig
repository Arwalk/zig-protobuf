//! Keeps the code blocks of the README equal to the sources that they show.
//!
//! A marker on the line above a code block names its source, relative to the repository:
//!
//!   <!-- snippet: path#tag -->  the block is the region of the file between the comments
//!                               `tag::tag[]` and `end::tag[]` (the syntax of AsciiDoc)
//!   <!-- snippet: path -->      the block is some consecutive lines of the file, for the files
//!                               that cannot have comments (generated code, output)
//!
//! The common indentation of the lines is not compared. A block of Zig or protobuf must have a
//! marker.
//!
//! Run with `zig build check-readme`, or `zig build update-readme` to write the regions into the
//! README.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The files that the markers name.
const Files = struct {
    context: *const anyopaque,
    /// `null` if the file cannot be read.
    readFn: *const fn (context: *const anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8,

    fn read(files: Files, arena: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
        return files.readFn(files.context, arena, path);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.ExpectedCommandAndReadme;
    const update = std.mem.eql(u8, args[1], "update");
    if (!update and !std.mem.eql(u8, args[1], "check")) return error.UnknownCommand;

    const files: Files = .{ .context = &io, .readFn = readFromDisk };
    const path = args[2];
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    var problems: std.ArrayList([]const u8) = .empty;
    const updated = try process(arena, readme, files, &problems);
    if (update and !std.mem.eql(u8, readme, updated)) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = updated });
        // What remains cannot be updated.
        problems.clearRetainingCapacity();
        _ = try process(arena, updated, files, &problems);
    }

    for (problems.items) |problem| std.debug.print("{s}:{s}\n", .{ path, problem });
    if (problems.items.len != 0) std.process.exit(1);
}

fn readFromDisk(context: *const anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
    const io: *const std.Io = @ptrCast(@alignCast(context));
    return std.Io.Dir.cwd().readFileAlloc(io.*, path, arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// The name of a `tag::name[]` or `end::name[]` comment.
fn tagName(line: []const u8, comptime prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    if (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) return null;
    const rest = line[start + prefix.len ..];
    const end = std.mem.indexOf(u8, rest, "[]") orelse return null;
    const name = rest[0..end];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t[") != null) return null;
    const after = rest[end + "[]".len ..];
    if (after.len > 0 and after[0] != ' ') return null;
    return name;
}

fn splitLines(arena: Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(arena, if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line);
    }
    // The text after a last end of line is not a line.
    if (lines.getLast().len == 0) _ = lines.pop();
    return lines.items;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// The lines without their common indentation, each with an end of line.
fn dedent(arena: Allocator, lines: []const []const u8) error{OutOfMemory}![]const u8 {
    var indentation: usize = std.math.maxInt(usize);
    for (lines) |line| {
        if (!isBlank(line)) indentation = @min(indentation, std.mem.indexOfNone(u8, line, " \t").?);
    }
    var result: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        if (!isBlank(line)) try result.appendSlice(arena, line[indentation..]);
        try result.append(arena, '\n');
    }
    return result.items;
}

/// The lines between the comments of `tag`, without the comments of other tags.
fn region(arena: Allocator, source: []const u8, tag: []const u8) error{ TagNotFound, TagNotClosed, TagDuplicated, OutOfMemory }![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var state: enum { before, inside, after } = .before;
    for (try splitLines(arena, source)) |line| {
        if (tagName(line, "tag::")) |name| {
            if (!std.mem.eql(u8, name, tag)) continue;
            if (state != .before) return error.TagDuplicated;
            state = .inside;
        } else if (tagName(line, "end::")) |name| {
            if (!std.mem.eql(u8, name, tag)) continue;
            switch (state) {
                .before => {},
                .inside => state = .after,
                .after => return error.TagDuplicated,
            }
        } else if (state == .inside) {
            try lines.append(arena, line);
        }
    }
    return switch (state) {
        .before => error.TagNotFound,
        .inside => error.TagNotClosed,
        .after => dedent(arena, lines.items),
    };
}

/// If the lines of the block are consecutive lines of the source.
fn contains(arena: Allocator, source: []const u8, block: []const u8) error{OutOfMemory}!bool {
    const source_lines = try splitLines(arena, source);
    const block_lines = try splitLines(arena, block);
    for (block_lines) |line| {
        if (!isBlank(line)) break;
    } else return false;
    if (block_lines.len > source_lines.len) return false;

    const expected = try dedent(arena, block_lines);
    for (0..source_lines.len - block_lines.len + 1) |start| {
        const window = source_lines[start..][0..block_lines.len];
        if (std.mem.eql(u8, expected, try dedent(arena, window))) return true;
    }
    return false;
}

/// The text of a line, without the characters of the lists and quotes that it is in.
fn markdown(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, line, " \t>-*+.)0123456789"), " \t");
}

const Fence = struct {
    char: u8,
    len: usize,
    /// What follows the characters of the fence.
    info: []const u8,

    fn parse(line: []const u8) ?Fence {
        const text = markdown(line);
        if (text.len == 0 or (text[0] != '`' and text[0] != '~')) return null;
        const len = std.mem.indexOfNone(u8, text, text[0..1]) orelse text.len;
        if (len < 3) return null;
        return .{ .char = text[0], .len = len, .info = std.mem.trim(u8, text[len..], " \t") };
    }

    fn isClosedBy(open: Fence, line: []const u8) bool {
        const close = parse(line) orelse return false;
        return close.char == open.char and close.len >= open.len and close.info.len == 0;
    }

    fn needsMarker(open: Fence) bool {
        const end = std.mem.indexOfAny(u8, open.info, " \t,{") orelse open.info.len;
        for ([_][]const u8{ "zig", "zon", "proto", "protobuf" }) |language| {
            if (std.ascii.eqlIgnoreCase(language, open.info[0..end])) return true;
        }
        return false;
    }
};

const Marker = struct {
    path: []const u8,
    tag: ?[]const u8,

    fn parse(line: []const u8) error{InvalidMarker}!?Marker {
        const text = markdown(line);
        if (!std.mem.startsWith(u8, text, "<!--")) return null;
        const comment = std.mem.trim(u8, text["<!--".len..], " \t");
        if (!std.mem.startsWith(u8, comment, "snippet")) return null;

        const prefix = "<!-- snippet: ";
        const suffix = " -->";
        if (text.len <= prefix.len + suffix.len or
            !std.mem.startsWith(u8, text, prefix) or
            !std.mem.endsWith(u8, text, suffix)) return error.InvalidMarker;
        const target = text[prefix.len .. text.len - suffix.len];
        const hash = std.mem.indexOfScalar(u8, target, '#') orelse return .{ .path = target, .tag = null };
        return .{ .path = target[0..hash], .tag = target[hash + 1 ..] };
    }
};

/// Returns the README with its tagged blocks refreshed. Adds one line to `problems` per fault.
fn process(
    arena: Allocator,
    readme: []const u8,
    files: Files,
    problems: *std.ArrayList([]const u8),
) error{OutOfMemory}![]const u8 {
    const lines = try splitLines(arena, readme);
    var result: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        var number = i + 1;
        const marker: ?Marker = Marker.parse(lines[i]) catch marker: {
            try report(arena, problems, number, "a snippet marker is `<!-- snippet: path#tag -->`", .{});
            break :marker null;
        };
        if (marker != null) {
            try result.append(arena, lines[i]);
            i += 1;
            if (i == lines.len or Fence.parse(lines[i]) == null) {
                try report(arena, problems, number, "a snippet marker must be on the line above a code block", .{});
                continue;
            }
        }

        const fence = Fence.parse(lines[i]) orelse {
            try result.append(arena, lines[i]);
            i += 1;
            continue;
        };
        const open = i;
        const close = for (lines[open + 1 ..], open + 1..) |line, n| {
            if (fence.isClosedBy(line)) break n;
        } else {
            try report(arena, problems, open + 1, "the block is not closed", .{});
            try result.appendSlice(arena, lines[open..]);
            break;
        };
        if (marker == null) number = open + 1;
        const body = lines[open + 1 .. close];
        try result.append(arena, lines[open]);
        try result.appendSlice(arena, try processBody(arena, lines[open], body, fence, marker, number, files, problems));
        try result.append(arena, lines[close]);
        i = close + 1;
    }

    const eol = if (std.mem.indexOf(u8, readme, "\r\n") != null) "\r\n" else "\n";
    const text = try std.mem.join(arena, eol, result.items);
    if (!std.mem.endsWith(u8, readme, "\n")) return text;
    return std.mem.concat(arena, u8, &.{ text, eol });
}

/// Returns the lines that the block must have, or `body` if they are not known.
fn processBody(
    arena: Allocator,
    fence_line: []const u8,
    body: []const []const u8,
    fence: Fence,
    optional_marker: ?Marker,
    number: usize,
    files: Files,
    problems: *std.ArrayList([]const u8),
) error{OutOfMemory}![]const []const u8 {
    const marker = optional_marker orelse {
        if (fence.needsMarker())
            try report(arena, problems, number, "a block of code must have a snippet marker on the line above", .{});
        return body;
    };
    if (fence_line[0] != fence.char) {
        try report(arena, problems, number, "a block with a snippet marker must not be indented", .{});
        return body;
    }
    const source = try files.read(arena, marker.path) orelse {
        try report(arena, problems, number, "cannot read {s}", .{marker.path});
        return body;
    };

    const text = try std.mem.join(arena, "\n", body);
    const tag = marker.tag orelse {
        if (!try contains(arena, source, text))
            try report(arena, problems, number, "the block is not consecutive lines of {s}, edit it", .{marker.path});
        return body;
    };
    const expected = region(arena, source, tag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report(arena, problems, number, "{s}#{s}: {s}", .{ marker.path, tag, @errorName(err) });
            return body;
        },
    };
    if (isBlank(std.mem.trim(u8, expected, "\n"))) {
        try report(arena, problems, number, "{s}#{s} is empty", .{ marker.path, tag });
        return body;
    }
    const expected_lines = try splitLines(arena, expected);
    if (!std.mem.eql(u8, text, try std.mem.join(arena, "\n", expected_lines)))
        try report(arena, problems, number, "the block is not {s}#{s}, run `zig build update-readme`", .{ marker.path, tag });
    return expected_lines;
}

fn report(
    arena: Allocator,
    problems: *std.ArrayList([]const u8),
    number: usize,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    try problems.append(arena, try std.fmt.allocPrint(arena, "{d}: " ++ format, .{number} ++ args));
}

const testing = std.testing;

const test_source =
    \\const a = 1;
    \\fn f() void {
    \\    // tag::body[]
    \\    const b = 2;
    \\    // tag::inner[]
    \\    if (b) {
    \\
    \\        c();
    \\    }
    \\    // end::inner[]
    \\    // end::body[]
    \\}
    \\
;

const test_region =
    \\const b = 2;
    \\if (b) {
    \\
    \\    c();
    \\}
    \\
;

const TestFile = struct { path: []const u8, content: []const u8 };

const test_files = [_]TestFile{
    .{ .path = "a.zig", .content = test_source },
    .{ .path = "crlf.zig", .content = "// tag::x[]\r\nconst x = 1;\r\n// end::x[]\r\n" },
    .{ .path = "bad.zig", .content =
    \\// tag::twice[]
    \\const a = 1;
    \\// end::twice[]
    \\// tag::twice[]
    \\const b = 1;
    \\// end::twice[]
    \\// tag::empty[]
    \\// end::empty[]
    \\// tag::open[]
    \\const c = 1;
    },
};

fn testRead(_: *const anyopaque, _: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
    for (test_files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.content;
    }
    return null;
}

/// Expects `problems` in a README, and `updated` as the README with its blocks refreshed.
fn expectProcess(readme: []const u8, updated: []const u8, problems: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files: Files = .{ .context = undefined, .readFn = testRead };

    var actual_problems: std.ArrayList([]const u8) = .empty;
    const actual = try process(arena, readme, files, &actual_problems);
    try testing.expectEqualStrings(
        try std.mem.join(arena, "\n", problems),
        try std.mem.join(arena, "\n", actual_problems.items),
    );
    try testing.expectEqualStrings(updated, actual);

    // An update has no more to do on its own result.
    var ignored: std.ArrayList([]const u8) = .empty;
    try testing.expectEqualStrings(updated, try process(arena, actual, files, &ignored));
}

fn expectProblems(readme: []const u8, problems: []const []const u8) !void {
    return expectProcess(readme, readme, problems);
}

fn expectRegion(expected: anyerror![]const u8, source: []const u8, tag: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const actual = region(arena_state.allocator(), source, tag);
    if (expected) |text| {
        try testing.expectEqualStrings(text, try actual);
    } else |err| {
        try testing.expectError(err, actual);
    }
}

test "a region has no common indentation and no tag lines" {
    try expectRegion(test_region, test_source, "body");
    try expectRegion("if (b) {\n\n    c();\n}\n", test_source, "inner");
}

test "a tag is a whole word" {
    try expectRegion(error.TagNotFound, test_source, "bod");
    try expectRegion(error.TagNotFound, "// xtag::body[]\na\n// end::body[]\n", "body");
    try expectRegion(error.TagNotFound, "// tag::body[]x\na\n// end::body[]\n", "body");
    try expectRegion("a\n", "<!-- tag::body[] -->\na\n<!-- end::body[] -->\n", "body");
}

test "a tag that is missing, not closed or duplicated" {
    try expectRegion(error.TagNotFound, test_source, "nope");
    try expectRegion(error.TagNotClosed, "// tag::a[]\nx\n", "a");
    try expectRegion(error.TagNotClosed, "// end::a[]\n// tag::a[]\nx\n", "a");
    try expectRegion(error.TagDuplicated, "// tag::a[]\n// tag::a[]\n// end::a[]\n", "a");
    try expectRegion(error.TagDuplicated, "// tag::a[]\n// end::a[]\n// end::a[]\n", "a");
}

test "a file contains consecutive lines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try contains(arena, test_source, "const a = 1;\nfn f() void {\n"));
    try testing.expect(try contains(arena, test_source, "if (b) {\n\n    c();\n}\n"));
    try testing.expect(try contains(arena, "a\r\nb\r\n", "a\nb\n"));
    try testing.expect(try contains(arena, "a\nb", "b\n"));
    try testing.expect(!try contains(arena, test_source, "const a = 1;\nconst b = 2;\n"));
    try testing.expect(!try contains(arena, test_source, "const a\n"));
    try testing.expect(!try contains(arena, test_source, "if (b) {\n\nc();\n}\n"));
    try testing.expect(!try contains(arena, test_source, "\n"));
    try testing.expect(!try contains(arena, "a\n", "a\na\na\n"));
}

test "blocks equal to their sources" {
    try expectProblems(
        "# Title\n\n<!-- snippet: a.zig#body -->\n```zig\n" ++ test_region ++ "```\n\ntext\n" ++
            "<!-- snippet: a.zig -->\n```zig\nconst a = 1;\n```\n```sh\nzig build\n```",
        &.{},
    );
}

test "a region that changed is refreshed" {
    const before = "x\n<!-- snippet: a.zig#body -->\n```zig\n";
    try expectProcess(
        before ++ "const b = 3;\n```\nend\n",
        before ++ test_region ++ "```\nend\n",
        &.{"2: the block is not a.zig#body, run `zig build update-readme`"},
    );
    try expectProcess(
        before ++ "```\nend\n",
        before ++ test_region ++ "```\nend\n",
        &.{"2: the block is not a.zig#body, run `zig build update-readme`"},
    );
}

test "lines that are not in the file stay" {
    try expectProblems(
        "<!-- snippet: a.zig -->\n```zig\nconst a = 2;\n```\n",
        &.{"1: the block is not consecutive lines of a.zig, edit it"},
    );
    try expectProblems(
        "<!-- snippet: a.zig -->\n```zig\n```\n",
        &.{"1: the block is not consecutive lines of a.zig, edit it"},
    );
}

test "a source that cannot be shown" {
    try expectProblems("<!-- snippet: no.zig#a -->\n```zig\n```\n", &.{"1: cannot read no.zig"});
    try expectProblems("<!-- snippet: a.zig#no -->\n```zig\n```\n", &.{"1: a.zig#no: TagNotFound"});
    try expectProblems("<!-- snippet: bad.zig#open -->\n```zig\n```\n", &.{"1: bad.zig#open: TagNotClosed"});
    try expectProblems("<!-- snippet: bad.zig#twice -->\n```zig\n```\n", &.{"1: bad.zig#twice: TagDuplicated"});
    try expectProblems("<!-- snippet: bad.zig#empty -->\n```zig\n```\n", &.{"1: bad.zig#empty is empty"});
    try expectProblems("<!-- snippet: a.zig# -->\n```zig\n```\n", &.{"1: a.zig#: TagNotFound"});
}

test "a block without a marker" {
    const problem = "a block of code must have a snippet marker on the line above";
    for ([_][]const u8{ "zig", "Zig", "proto", "protobuf", "zon", "zig title=x", " zig" }) |info| {
        const readme = try std.mem.concat(testing.allocator, u8, &.{ "\n```", info, "\na\n```\n" });
        defer testing.allocator.free(readme);
        try expectProblems(readme, &.{"2: " ++ problem});
    }
    try expectProblems("~~~zig\na\n~~~\n", &.{"1: " ++ problem});
    try expectProblems("1. x\n    ```zig\n    a\n    ```\n", &.{"2: " ++ problem});
    try expectProblems("- ```zig\n  a\n  ```\n", &.{"1: " ++ problem});
    try expectProblems("1. ```zig\n   a\n   ```\n", &.{"1: " ++ problem});
    try expectProblems("> ```zig\n> a\n> ```\n", &.{"1: " ++ problem});
    try expectProblems("<!-- snippet: a.zig -->\n\n```zig\na\n```\n", &.{
        "1: a snippet marker must be on the line above a code block",
        "3: " ++ problem,
    });
    // Not code.
    try expectProblems("````md\n```zig\na\n```\n````\n```sh\na\n```\n", &.{});
}

test "a block that cannot be refreshed" {
    try expectProblems(
        "1. x\n    <!-- snippet: a.zig#body -->\n    ```zig\n    a\n    ```\n",
        &.{"2: a block with a snippet marker must not be indented"},
    );
    try expectProblems("<!-- snippet: a.zig#body -->\n", &.{"1: a snippet marker must be on the line above a code block"});
    try expectProblems("<!-- snippet: a.zig#body -->\n```zig\na\n", &.{"2: the block is not closed"});
    try expectProblems("```sh\na\n", &.{"1: the block is not closed"});
    try expectProblems("<!--snippet a.zig-->\n```sh\na\n```\n", &.{"1: a snippet marker is `<!-- snippet: path#tag -->`"});
}

test "line endings" {
    try expectProblems("<!-- snippet: crlf.zig#x -->\n```zig\nconst x = 1;\n```\n", &.{});
    try expectProblems("<!-- snippet: crlf.zig#x -->\r\n```zig\r\nconst x = 1;\r\n```\r\n", &.{});
    try expectProblems("<!-- snippet: a.zig#inner -->\r\n```zig\r\nif (b) {\r\n\r\n    c();\r\n}\r\n```\r\n", &.{});
    try expectProcess(
        "<!-- snippet: crlf.zig#x -->\r\n```zig\r\n```\r\n",
        "<!-- snippet: crlf.zig#x -->\r\n```zig\r\nconst x = 1;\r\n```\r\n",
        &.{"1: the block is not crlf.zig#x, run `zig build update-readme`"},
    );
}
