//! Keeps the blocks of the README equal to the sources that they show.
//!
//! A marker on the line above a block names its source, relative to the repository:
//!
//!   <!-- snippet: path#tag -->  the block is the region of the file between the comments
//!                               `tag::tag[]` and `end::tag[]` (the syntax of AsciiDoc)
//!   <!-- snippet: path -->      the block is the file
//!   <!-- excerpt: path -->      the block is some consecutive lines of the file, for a file that
//!                               cannot have comments (generated code)
//!
//! The comments of the tags and the common indentation of the lines are not shown. All blocks must
//! have a marker, except those of `sh`. Markdown has many ways to write a block, thus all the ways
//! that this program does not read are faults.
//!
//! Run with `zig build check-readme`, or `zig build update-readme` to write the snippets into the
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

/// The lines of a file, without the comments of the tags.
fn whole(arena: Allocator, source: []const u8) error{OutOfMemory}![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (try splitLines(arena, source)) |line| {
        if (tagName(line, "tag::") == null and tagName(line, "end::") == null) try lines.append(arena, line);
    }
    return dedent(arena, lines.items);
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

const Fence = struct {
    char: u8,
    len: usize,
    /// What follows the characters of the fence.
    info: []const u8,

    /// A fence at the start of the text.
    fn parse(text: []const u8) ?Fence {
        if (text.len == 0 or (text[0] != '`' and text[0] != '~')) return null;
        const len = std.mem.indexOfNone(u8, text, text[0..1]) orelse text.len;
        if (len < 3) return null;
        const info = std.mem.trim(u8, text[len..], " \t");
        // Code in a line of text.
        if (text[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
        return .{ .char = text[0], .len = len, .info = info };
    }

    /// A fence that is indented, in a list or in a quote.
    fn isNested(line: []const u8) bool {
        const text = std.mem.trimStart(u8, line, " \t>-*+.)0123456789");
        return text.len < line.len and parse(text) != null;
    }

    fn isClosedBy(open: Fence, line: []const u8) bool {
        const text = std.mem.trimStart(u8, line, " ");
        if (line.len - text.len > 3) return false;
        const close = parse(text) orelse return false;
        return close.char == open.char and close.len >= open.len and close.info.len == 0;
    }
};

const Marker = struct {
    kind: enum { snippet, excerpt },
    path: []const u8,
    tag: ?[]const u8 = null,

    fn parse(line: []const u8) error{InvalidMarker}!?Marker {
        if (std.mem.indexOf(u8, line, "<!--") == null) return null;
        const suffix = " -->";
        if (!std.mem.endsWith(u8, line, suffix)) return error.InvalidMarker;
        const text = line[0 .. line.len - suffix.len];

        const excerpt = "<!-- excerpt: ";
        if (std.mem.startsWith(u8, text, excerpt)) {
            const path = text[excerpt.len..];
            if (!isPath(path)) return error.InvalidMarker;
            return .{ .kind = .excerpt, .path = path };
        }
        const snippet = "<!-- snippet: ";
        if (!std.mem.startsWith(u8, text, snippet)) return error.InvalidMarker;
        const named = text[snippet.len..];
        const end = std.mem.indexOfScalar(u8, named, '#') orelse named.len;
        if (!isPath(named[0..end])) return error.InvalidMarker;
        return .{
            .kind = .snippet,
            .path = named[0..end],
            .tag = if (end < named.len) named[end + 1 ..] else null,
        };
    }

    fn isPath(text: []const u8) bool {
        return text.len > 0 and std.mem.indexOfAny(u8, text, " #") == null;
    }

    /// As it is written in the README.
    fn target(marker: Marker, arena: Allocator) error{OutOfMemory}![]const u8 {
        const tag = marker.tag orelse return marker.path;
        return std.fmt.allocPrint(arena, "{s}#{s}", .{ marker.path, tag });
    }
};

/// Returns the README with its snippets refreshed. Adds one line to `problems` per fault.
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
        var invalid_marker = false;
        const marker: ?Marker = Marker.parse(lines[i]) catch marker: {
            invalid_marker = true;
            try report(arena, problems, number, "a comment must be `<!-- snippet: path -->`, " ++
                "`<!-- snippet: path#tag -->` or `<!-- excerpt: path -->`", .{});
            break :marker null;
        };
        if (marker != null) {
            try result.append(arena, lines[i]);
            i += 1;
            if (i == lines.len or Fence.parse(lines[i]) == null) {
                try report(arena, problems, number, "a marker must be on the line above a block", .{});
                continue;
            }
        }

        const open = i;
        const fence = Fence.parse(lines[open]) orelse {
            if (!invalid_marker) try checkText(arena, lines[open], number, problems);
            try result.append(arena, lines[open]);
            i += 1;
            continue;
        };
        const close = for (lines[open + 1 ..], open + 1..) |line, n| {
            if (fence.isClosedBy(line)) break n;
        } else {
            try report(arena, problems, open + 1, "the block is not closed", .{});
            try result.appendSlice(arena, lines[open..]);
            break;
        };
        const body = lines[open + 1 .. close];
        try result.append(arena, lines[open]);
        if (marker) |m| {
            try result.appendSlice(arena, try processBlock(arena, body, fence, m, number, files, problems));
        } else {
            number = open + 1;
            if (!std.mem.eql(u8, fence.info, "sh"))
                try report(arena, problems, number, "a block must have a snippet or excerpt marker on the line above", .{});
            try result.appendSlice(arena, body);
        }
        try result.append(arena, lines[close]);
        i = close + 1;
    }

    const eol = if (std.mem.indexOf(u8, readme, "\r\n") != null) "\r\n" else "\n";
    const text = try std.mem.join(arena, eol, result.items);
    if (!std.mem.endsWith(u8, readme, "\n")) return text;
    return std.mem.concat(arena, u8, &.{ text, eol });
}

/// Reports the code of a line that is not in a block.
fn checkText(arena: Allocator, line: []const u8, number: usize, problems: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    if (Fence.isNested(line)) {
        try report(arena, problems, number, "a block must not be indented, in a list or in a quote", .{});
    } else if (std.ascii.findIgnoreCase(line, "<pre") != null) {
        try report(arena, problems, number, "use a block with a marker, not <pre>", .{});
    } else if (!isBlank(line) and (line[0] == '\t' or std.mem.startsWith(u8, line, "    "))) {
        try report(arena, problems, number, "an indented line can be code, use a block with a marker", .{});
    }
}

/// Returns the lines that the block must have, or `body` if they are not known.
fn processBlock(
    arena: Allocator,
    body: []const []const u8,
    fence: Fence,
    marker: Marker,
    number: usize,
    files: Files,
    problems: *std.ArrayList([]const u8),
) error{OutOfMemory}![]const []const u8 {
    const source = try files.read(arena, marker.path) orelse {
        try report(arena, problems, number, "cannot read {s}", .{marker.path});
        return body;
    };
    const text = try std.mem.join(arena, "\n", body);
    const target = try marker.target(arena);
    if (marker.kind == .excerpt) {
        if (!try contains(arena, source, text))
            try report(arena, problems, number, "the block is not consecutive lines of {s}, edit it", .{target});
        return body;
    }

    const expected = if (marker.tag) |tag| region(arena, source, tag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report(arena, problems, number, "{s}: {s}", .{ target, @errorName(err) });
            return body;
        },
    } else try whole(arena, source);
    if (std.mem.trim(u8, expected, " \t\n").len == 0) {
        try report(arena, problems, number, "{s} is empty", .{target});
        return body;
    }
    const expected_lines = try splitLines(arena, expected);
    for (expected_lines) |line| {
        if (!fence.isClosedBy(line)) continue;
        try report(arena, problems, number, "{s} has a line that closes the block", .{target});
        return body;
    }
    if (!std.mem.eql(u8, text, try std.mem.join(arena, "\n", expected_lines)))
        try report(arena, problems, number, "the block is not {s}, run `zig build update-readme`", .{target});
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
    .{ .path = "whole.txt", .content = "one\n\ntwo\n" },
    .{ .path = "comment.txt", .content = "/*\n * ```\n */\n" },
    .{ .path = "fence.txt", .content = "a\n```\nb\n" },
    .{ .path = "md.txt", .content = "```zig\na\n```\n" },
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
            "<!-- excerpt: a.zig -->\n```zig\nconst a = 1;\n```\n" ++
            "<!-- snippet: whole.txt -->\n```text\none\n\ntwo\n```\n```sh\nzig build\n```",
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

test "a file is shown whole, without its tags" {
    const refreshed = "<!-- snippet: whole.txt -->\n```text\none\n\ntwo\n```\n";
    const problem = "1: the block is not whole.txt, run `zig build update-readme`";
    try expectProcess("<!-- snippet: whole.txt -->\n```text\none\n```\n", refreshed, &.{problem});
    try expectProcess("<!-- snippet: whole.txt -->\n```text\ntwo\n```\n", refreshed, &.{problem});
    try expectProblems("<!-- snippet: crlf.zig -->\n```zig\nconst x = 1;\n```\n", &.{});
}

test "lines that are not in the file stay" {
    const problem = "1: the block is not consecutive lines of a.zig, edit it";
    try expectProblems("<!-- excerpt: a.zig -->\n```zig\nconst a = 2;\n```\n", &.{problem});
    try expectProblems("<!-- excerpt: a.zig -->\n```zig\n```\n", &.{problem});
}

test "a source that cannot be shown" {
    try expectProblems("<!-- snippet: no.zig#a -->\n```zig\n```\n", &.{"1: cannot read no.zig"});
    try expectProblems("<!-- excerpt: no.zig -->\n```zig\n```\n", &.{"1: cannot read no.zig"});
    try expectProblems("<!-- snippet: a.zig#no -->\n```zig\n```\n", &.{"1: a.zig#no: TagNotFound"});
    try expectProblems("<!-- snippet: bad.zig#open -->\n```zig\n```\n", &.{"1: bad.zig#open: TagNotClosed"});
    try expectProblems("<!-- snippet: bad.zig#twice -->\n```zig\n```\n", &.{"1: bad.zig#twice: TagDuplicated"});
    try expectProblems("<!-- snippet: bad.zig#empty -->\n```zig\n```\n", &.{"1: bad.zig#empty is empty"});
    try expectProblems("<!-- snippet: a.zig# -->\n```zig\n```\n", &.{"1: a.zig#: TagNotFound"});
    try expectProblems("<!-- snippet: fence.txt -->\n```text\n```\n", &.{"1: fence.txt has a line that closes the block"});
}

test "a fence in a comment of the source does not close the block" {
    const block = "<!-- snippet: comment.txt -->\n```text\n/*\n * ```\n */\n```\n";
    try expectProblems(block, &.{});
    try expectProcess(
        "<!-- snippet: comment.txt -->\n```text\n```\n",
        block,
        &.{"1: the block is not comment.txt, run `zig build update-readme`"},
    );
}

test "a block without a marker" {
    const problem = "a block must have a snippet or excerpt marker on the line above";
    for ([_][]const u8{
        "",     "zig",     "Zig",    "zig title=x", " zig",     "{.zig}", "zig:main",
        "text", "ziglang", "zig,sh", "sh,zig",      "sh title",
    }) |info| {
        const readme = try std.mem.concat(testing.allocator, u8, &.{ "\n```", info, "\na\n```\n" });
        defer testing.allocator.free(readme);
        try expectProblems(readme, &.{"2: " ++ problem});
    }
    try expectProblems("~~~zig\na\n~~~\n", &.{"1: " ++ problem});
    try expectProblems("<!-- snippet: a.zig#body -->\n\n```zig\na\n```\n", &.{
        "1: a marker must be on the line above a block",
        "3: " ++ problem,
    });
    // A block in another block is only text.
    try expectProblems("<!-- snippet: md.txt -->\n````md\n```zig\na\n```\n````\n```sh\na\n```\n", &.{});
    // Not a fence, so it does not hide the block that follows.
    try expectProblems("```a``` b\n```zig\na\n```\n", &.{"2: " ++ problem});
}

test "code in other forms" {
    const indented = "a block must not be indented, in a list or in a quote";
    for ([_][]const u8{ " ```sh", "- ```sh", "1. ```zig", "> ```sh", "  ~~~zig" }) |line| {
        const readme = try std.mem.concat(testing.allocator, u8, &.{ line, "\n```sh\na\n```\n" });
        defer testing.allocator.free(readme);
        try expectProblems(readme, &.{"1: " ++ indented});
    }
    try expectProblems("x\n\n    const a = 1;\n", &.{"3: an indented line can be code, use a block with a marker"});
    try expectProblems("x\n\n\tconst a = 1;\n", &.{"3: an indented line can be code, use a block with a marker"});
    for ([_][]const u8{ "<pre>", "x <PRE lang=\"zig\">" }) |line| {
        try expectProblems(line, &.{"1: use a block with a marker, not <pre>"});
    }
}

test "a block that cannot be refreshed" {
    try expectProblems("<!-- snippet: a.zig#body -->\n", &.{"1: a marker must be on the line above a block"});
    try expectProblems("<!-- snippet: a.zig#body -->\n```zig\na\n", &.{"2: the block is not closed"});
    try expectProblems("```sh\na\n", &.{"1: the block is not closed"});
}

test "a comment that is not a marker" {
    for ([_][]const u8{
        "<!--snippet a.zig-->",
        "<!-- Snippet: a.zig -->",
        "<!-- snipet: a.zig -->",
        "x <!-- snippet: a.zig -->",
        " <!-- snippet: a.zig -->",
        "<!-- snippet:  -->",
        "<!-- excerpt: a.zig#body -->",
    }) |line| {
        const readme = try std.mem.concat(testing.allocator, u8, &.{ line, "\n```sh\na\n```\n" });
        defer testing.allocator.free(readme);
        try expectProblems(readme, &.{"1: a comment must be `<!-- snippet: path -->`, `<!-- snippet: path#tag -->` or `<!-- excerpt: path -->`"});
    }
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
