const warn = @import("std").debug.warn;
const std = @import("std");
const pb = @import("protobuf");
const plugin = @import("google/protobuf/compiler.pb.zig");
const descriptor = @import("google/protobuf.pb.zig");
const mem = std.mem;
const FullName = @import("./FullName.zig").FullName;

pub const std_options: std.Options = .{ .log_scope_levels = &[_]std.log.ScopeLevel{.{ .level = .warn, .scope = .zig_protobuf }} };

pub fn main() !void {
    var stdin_buf: [4096]u8 = undefined;
    const allocator = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    const io = threaded.io();
    var stdin = std.Io.File.stdin().reader(io, &stdin_buf);

    const request: plugin.CodeGeneratorRequest = try .decode(
        &stdin.interface,
        allocator,
    );

    var ctx: GenerationContext = try .init(allocator, request);

    try ctx.processRequest(io, allocator);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try ctx.res.encode(&stdout.interface, allocator);
    try stdout.interface.flush();
}

const GenerationContext = struct {
    req: plugin.CodeGeneratorRequest,
    res: plugin.CodeGeneratorResponse,

    /// map of known packages
    known_packages: std.StringHashMap(FullName),

    /// map of "package.fully.qualified.names" to output string lines
    fqn_lines: std.StringHashMap(std.ArrayList([]const u8)),

    /// map of message names to their dependencies
    message_deps: std.StringHashMap(std.ArrayList([]const u8)),

    /// map of package names to the references of the extensions they declare
    package_extensions: std.StringHashMap(std.ArrayList([]const u8)),

    /// map of ".package.fully.qualified.Name" to every message in the request
    messages: std.StringHashMap(descriptor.DescriptorProto),
    /// map of ".package.fully.qualified.Name" to every enum in the request
    enums: std.StringHashMap(descriptor.EnumDescriptorProto),
    preserve_unknown_fields: bool,
    /// Accept the in-development `edition = "UNSTABLE"`, whose features may
    /// change in any protobuf release. protoc also needs `--experimental_editions`.
    experimental_editions: bool,

    /// Helper struct for working with SourceCodeInfo
    const SourceCodeInfo = struct {
        /// Appends a comment as doc-comment lines (///) to the output
        fn appendComment(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), raw_comment: []const u8) !void {
            // Trim trailing newlines from the comment first
            var trimmed = raw_comment;
            while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }

            var comment_lines = std.mem.splitScalar(u8, trimmed, '\n');

            while (comment_lines.next()) |comment_line| {
                // Strip leading forward slashes that protobuf includes from the source
                var line = comment_line;
                while (line.len > 0 and (line[0] == '/' or line[0] == ' ')) {
                    line = line[1..];
                }

                // Use /// for doc comments as per issue discussion
                try lines.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "/// {s}\n",
                    .{line},
                ));
            }
        }

        /// Get source code location for an item in a repeated field
        fn getRepeatedFieldLocation(
            file: descriptor.FileDescriptorProto,
            root_path: []const i32,
            field_number: i32,
            index: usize,
        ) ?descriptor.SourceCodeInfo.Location {
            const sci = file.source_code_info orelse return null;

            for (sci.location.items) |location| {
                const path = location.path.items;

                if (path.len != root_path.len + 2) continue;
                if (!std.mem.eql(i32, root_path, path[0..root_path.len]))
                    continue;

                const rem_path = path[root_path.len..];

                if (rem_path[0] != field_number) continue;
                if (rem_path[1] != @as(i32, @intCast(index))) continue;

                return location;
            }

            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator, request: plugin.CodeGeneratorRequest) !GenerationContext {
        var ctx: GenerationContext = .{
            .req = request,
            .res = .{},
            .known_packages = .init(allocator),
            .fqn_lines = .init(allocator),
            .message_deps = .init(allocator),
            .package_extensions = .init(allocator),
            .messages = .init(allocator),
            .enums = .init(allocator),
            .preserve_unknown_fields = false,
            .experimental_editions = false,
        };

        try ctx.parseParameter(allocator);
        return ctx;
    }

    fn parseParameter(self: *GenerationContext, allocator: std.mem.Allocator) !void {
        const parameter = self.req.parameter orelse return;

        var params = std.mem.splitScalar(u8, parameter, ',');
        while (params.next()) |param| {
            if (param.len == 0) continue;

            if (std.mem.eql(u8, param, "preserve_unknown_fields") or
                std.mem.eql(u8, param, "preserve_unknown_fields=true"))
            {
                self.preserve_unknown_fields = true;
                continue;
            }

            if (std.mem.eql(u8, param, "preserve_unknown_fields=false")) {
                self.preserve_unknown_fields = false;
                continue;
            }

            if (std.mem.eql(u8, param, "experimental_editions") or
                std.mem.eql(u8, param, "experimental_editions=true"))
            {
                self.experimental_editions = true;
                continue;
            }

            if (std.mem.eql(u8, param, "experimental_editions=false")) {
                self.experimental_editions = false;
                continue;
            }

            self.res.@"error" = try std.fmt.allocPrint(
                allocator,
                "unsupported protoc-gen-zig parameter: {s}",
                .{param},
            );
            return;
        }
    }

    /// Newest edition accepted: edition 2026, or the unstable edition with
    /// `experimental_editions`. The unstable edition has no feature defaults
    /// of its own, so it resolves like the newest edition.
    fn maximumEdition(self: *const GenerationContext) descriptor.Edition {
        return if (self.experimental_editions) .EDITION_UNSTABLE else maximum_edition;
    }

    pub fn processRequest(self: *GenerationContext, io: std.Io, allocator: std.mem.Allocator) !void {
        if (self.res.@"error" != null) return;

        defer {
            // Clean up message dependencies
            var it = self.message_deps.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            self.message_deps.deinit();
        }

        for (self.req.proto_file.items) |file| {
            const t: descriptor.FileDescriptorProto = file;

            if (t.package) |package| {
                try self.known_packages.put(package, FullName{ .buf = package });
            } else {
                self.res.@"error" = try std.fmt.allocPrint(
                    allocator,
                    "ERROR Package directive missing in {s}\n",
                    .{file.name.?},
                );
                return;
            }
        }

        for (self.req.proto_file.items) |file| {
            const edition = @intFromEnum(fileEdition(file));
            if (edition < @intFromEnum(minimum_edition) or edition > @intFromEnum(self.maximumEdition())) {
                self.res.@"error" = try std.fmt.allocPrint(
                    allocator,
                    "ERROR unsupported edition {} in {s}\n",
                    .{ edition, file.name.? },
                );
                return;
            }
            const prefix = try std.mem.concat(allocator, u8, &.{ ".", file.package.? });
            try self.indexMessages(allocator, prefix, file.message_type);
            try self.indexEnums(allocator, prefix, file.enum_type);
        }

        for (self.req.proto_file.items) |file| {
            const t: descriptor.FileDescriptorProto = file;

            const name = FullName{ .buf = t.package.? };

            try self.printFileDeclarations(io, allocator, name, file);
        }

        var it = self.fqn_lines.iterator();
        while (it.next()) |entry| {
            var ret: plugin.CodeGeneratorResponse.File = .{};
            var name_buf: [std.fs.max_path_bytes]u8 = undefined;

            ret.name = try allocator.dupe(u8, packageToFileName(entry.key_ptr.*, &name_buf));
            ret.content = try std.mem.concat(allocator, u8, entry.value_ptr.*.items);
            if (try self.packageExtensionsDeclaration(allocator, entry.key_ptr.*)) |declaration| {
                ret.content = try std.mem.concat(allocator, u8, &.{ ret.content.?, declaration });
            }
            // Only files with fields using non-default features need `fdf`.
            if (std.mem.indexOf(u8, ret.content.?, "fdf(") != null) {
                ret.content = try std.mem.replaceOwned(
                    u8,
                    allocator,
                    ret.content.?,
                    "const fd = protobuf.fd;\n",
                    "const fd = protobuf.fd;\nconst fdf = protobuf.fdf;\n",
                );
            }

            try self.res.file.append(allocator, ret);
        }

        self.res.supported_features =
            @intFromEnum(plugin.CodeGeneratorResponse.Feature.FEATURE_PROTO3_OPTIONAL) |
            @intFromEnum(plugin.CodeGeneratorResponse.Feature.FEATURE_SUPPORTS_EDITIONS);
        self.res.minimum_edition = @intFromEnum(minimum_edition);
        self.res.maximum_edition = @intFromEnum(self.maximumEdition());
    }

    /// Records `messages` and their nested messages, keyed by their fully
    /// qualified name as used in `FieldDescriptorProto.type_name`.
    fn indexMessages(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        messages: std.ArrayList(descriptor.DescriptorProto),
    ) !void {
        for (messages.items) |m| {
            const name = try std.mem.concat(allocator, u8, &.{ prefix, ".", m.name.? });
            try self.messages.put(name, m);
            try self.indexMessages(allocator, name, m.nested_type);
            try self.indexEnums(allocator, name, m.enum_type);
        }
    }

    /// Records `enums`, keyed by their fully qualified name as used in
    /// `FieldDescriptorProto.type_name`.
    fn indexEnums(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        enums: std.ArrayList(descriptor.EnumDescriptorProto),
    ) !void {
        for (enums.items) |e| {
            const name = try std.mem.concat(allocator, u8, &.{ prefix, ".", e.name.? });
            try self.enums.put(name, e);
        }
    }

    /// Whether `field` of `message` is a submessage encoded as a group. Map
    /// fields and the fields of map entries are always length-prefixed.
    fn isDelimited(
        self: *GenerationContext,
        message: descriptor.DescriptorProto,
        field: descriptor.FieldDescriptorProto,
        features: Features,
    ) bool {
        const t = field.type orelse return false;
        if (t != .TYPE_MESSAGE and t != .TYPE_GROUP) return false;
        if (features.message_encoding != .DELIMITED) return false;
        if (isMapEntry(message)) return false;
        if (field.type_name) |type_name| {
            if (self.messages.get(type_name)) |target| {
                if (isMapEntry(target)) return false;
            }
        }
        return true;
    }

    fn getOutputLines(self: *GenerationContext, io: std.Io, allocator: std.mem.Allocator, name: FullName) !*std.ArrayList([]const u8) {
        const entry = try self.fqn_lines.getOrPut(name.buf);

        if (!entry.found_existing) {
            var lines: std.ArrayList([]const u8) = .empty;

            try lines.append(allocator, try std.fmt.allocPrint(allocator,
                \\// Code generated by protoc-gen-zig
                \\ ///! package {s}
                \\const std = @import("std");
                \\
                \\const protobuf = @import("protobuf");
                \\const fd = protobuf.fd;
                \\
            , .{name.buf}));

            // collect all imports from all files sharing the same package
            var importedPackages: std.StringHashMap(bool) = .init(allocator);

            for (self.req.proto_file.items) |file| {
                if (name.eqlString(file.package.?)) {
                    for (file.dependency.items) |dep| {
                        for (self.req.proto_file.items, 0..) |item, index| {
                            if (std.mem.eql(u8, dep, item.name.?)) {
                                var is_public_dep: bool = false;

                                // find whether an import is marked as public
                                for (file.public_dependency.items) |public_dep| {
                                    if (public_dep == index) {
                                        is_public_dep = true;
                                    }
                                }

                                try importedPackages.put(item.package.?, is_public_dep);
                            }
                        }
                    }
                }
            }

            var it = importedPackages.iterator();
            while (it.next()) |package| {
                if (!std.mem.eql(u8, package.key_ptr.*, name.buf)) {
                    try lines.append(
                        allocator,
                        try std.fmt.allocPrint(
                            allocator,
                            "/// import package {s}\n",
                            .{package.key_ptr.*},
                        ),
                    );

                    const optional_pub_directive: []const u8 = if (package.value_ptr.*) "pub const" else "const";

                    try lines.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "{s} {!s} = @import(\"{!s}\");\n",
                        .{
                            optional_pub_directive,
                            escapeFqn(allocator, package.key_ptr.*),
                            resolvePath(io, allocator, name.buf, package.key_ptr.*),
                        },
                    ));
                }
            }

            entry.value_ptr.* = lines;
        }

        return entry.value_ptr;
    }

    /// resolves an import path from the file A relative to B
    fn resolvePath(io: std.Io, allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
        var a_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var b_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const aPath = std.fs.path.dirname(packageToFileName(a, &a_path_buf)) orelse "";
        const bPath = packageToFileName(b, &b_path_buf);

        // Get actual current working directory
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        // to resolve some escaping oddities, the windows path separator is canonicalized to /
        const resolvedRelativePath = try std.fs.path.relative(allocator, cwd, null, aPath, bPath);
        return std.mem.replaceOwned(u8, allocator, resolvedRelativePath, "\\", "/");
    }

    pub fn printFileDeclarations(
        self: *GenerationContext,
        io: std.Io,
        allocator: std.mem.Allocator,
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
    ) !void {
        const lines = try self.getOutputLines(io, allocator, fqn);

        // For file-level elements, root_path is empty
        const file_root_path: []const i32 = &.{};
        const file_features: Features = .forFile(file);
        // Field number 5 for enum_type in FileDescriptorProto
        try self.generateEnums(allocator, lines, fqn, file, file.enum_type, file_root_path, 5, file_features);
        // Field number 4 for message_type in FileDescriptorProto
        try self.generateMessages(allocator, lines, fqn, file, null, file.message_type, file_root_path, 4, file_features);
        try self.generateExtensions(allocator, lines, fqn, file, file.extension, file_features);
        // Field number 6 for service in FileDescriptorProto
        try self.generateServices(allocator, lines, fqn, file, file.service, file_root_path, 6);
    }

    // WKT FQNs that are re-exported from protobuf.wkt instead of being generated inline.
    const wkt_message_fqns = [_][]const u8{
        "google.protobuf.Any",
        "google.protobuf.Duration",
        "google.protobuf.Empty",
        "google.protobuf.FieldMask",
        "google.protobuf.Struct",
        "google.protobuf.Value",
        "google.protobuf.ListValue",
        "google.protobuf.Timestamp",
        "google.protobuf.DoubleValue",
        "google.protobuf.FloatValue",
        "google.protobuf.Int64Value",
        "google.protobuf.UInt64Value",
        "google.protobuf.Int32Value",
        "google.protobuf.UInt32Value",
        "google.protobuf.BoolValue",
        "google.protobuf.StringValue",
        "google.protobuf.BytesValue",
    };
    const wkt_enum_fqns = [_][]const u8{
        "google.protobuf.NullValue",
    };

    fn isWktMessage(fqn: FullName) bool {
        for (wkt_message_fqns) |wkt_fqn| {
            if (std.mem.eql(u8, fqn.buf, wkt_fqn)) return true;
            // Also skip nested types inside WKT messages (e.g. Struct.FieldsEntry)
            if (std.mem.startsWith(u8, fqn.buf, wkt_fqn) and
                fqn.buf.len > wkt_fqn.len and
                fqn.buf[wkt_fqn.len] == '.')
                return true;
        }
        return false;
    }

    fn isWktEnum(fqn: FullName, name: []const u8) bool {
        const full = std.mem.concat(std.heap.page_allocator, u8, &.{ fqn.buf, ".", name }) catch return false;
        defer std.heap.page_allocator.free(full);
        for (wkt_enum_fqns) |wkt_fqn| {
            if (std.mem.eql(u8, full, wkt_fqn)) return true;
        }
        return false;
    }

    fn generateEnums(
        ctx: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        enums: std.ArrayList(descriptor.EnumDescriptorProto),
        root_path: []const i32,
        enum_field_number: i32,
        scope_features: Features,
    ) !void {
        _ = ctx;

        for (enums.items, 0..) |theEnum, enum_i| {
            const e: descriptor.EnumDescriptorProto = theEnum;

            try lines.append(allocator, "\n");

            // WKT enums are re-exported from protobuf.wkt
            if (isWktEnum(fqn, e.name.?)) {
                try lines.append(
                    allocator,
                    try std.fmt.allocPrint(allocator, "pub const {s} = protobuf.wkt.{s};\n", .{ e.name.?, e.name.? }),
                );
                continue;
            }

            // Add leading comment if available
            if (SourceCodeInfo.getRepeatedFieldLocation(
                file,
                root_path,
                enum_field_number,
                enum_i,
            )) |loc| {
                if (loc.leading_comments) |leading_comments| {
                    try SourceCodeInfo.appendComment(allocator, lines, leading_comments);
                }
            }

            const allow_alias = if (e.options) |options| options.allow_alias orelse false else false;

            try lines.append(
                allocator,
                try std.fmt.allocPrint(allocator, "pub const {s} = enum(i32) {{\n", .{e.name.?}),
            );

            for (e.value.items, 0..) |elem, elem_i| {
                if (allow_alias and hasPreviousEnumNumber(e.value.items[0..elem_i], elem.number orelse 0)) {
                    continue;
                }

                try lines.append(
                    allocator,
                    try std.fmt.allocPrint(allocator, "   {s} = {},\n", .{ elem.name.?, elem.number orelse 0 }),
                );
            }

            // Open enums accept any value. Closed enums are exhaustive: values
            // matching no enumerator are decoded as unknown fields instead.
            const enum_features = scope_features.merge(if (e.options) |o| o.features else null);
            if (enum_features.enum_type == .OPEN) {
                try lines.append(allocator, "    _,\n");
            }
            if (allow_alias and hasEnumAliases(e)) {
                try lines.append(allocator,
                    \\    // allow_alias = true: these additional names also map to an emitted enum value.
                    \\    pub const _json_aliases = &[_]struct { name: []const u8, value: i32 }{
                );
                for (e.value.items, 0..) |elem, elem_i| {
                    const number = elem.number orelse 0;
                    if (!hasPreviousEnumNumber(e.value.items[0..elem_i], number)) continue;
                    try lines.append(
                        allocator,
                        try std.fmt.allocPrint(allocator, "        .{{ .name = \"{s}\", .value = {} }},\n", .{ elem.name.?, number }),
                    );
                }
                try lines.append(allocator,
                    \\    };
                    \\
                );
            }
            try lines.append(allocator, "};\n\n");
        }
    }

    fn hasPreviousEnumNumber(values: []const descriptor.EnumValueDescriptorProto, number: i32) bool {
        for (values) |value| {
            if ((value.number orelse 0) == number) return true;
        }
        return false;
    }

    fn hasEnumAliases(e: descriptor.EnumDescriptorProto) bool {
        for (e.value.items, 0..) |elem, elem_i| {
            if (hasPreviousEnumNumber(e.value.items[0..elem_i], elem.number orelse 0)) return true;
        }
        return false;
    }

    fn escapeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        if (std.zig.Token.keywords.get(name)) |_|
            return try std.fmt.allocPrint(allocator, "@\"{s}\"", .{name})
        else
            return name;
    }

    fn fieldTypeFqn(
        ctx: *GenerationContext,
        allocator: std.mem.Allocator,
        parentFqn: FullName,
        file: descriptor.FileDescriptorProto,
        field: descriptor.FieldDescriptorProto,
    ) ![]const u8 {
        if (field.type_name) |typeName| {
            const fullTypeName = FullName{ .buf = typeName[1..] };
            if (fullTypeName.parent()) |parent| {
                if (parent.eql(parentFqn)) {
                    const diff_idx = std.mem.indexOfDiff(
                        u8,
                        fullTypeName.buf,
                        file.package.?,
                    ).?;
                    return fullTypeName.buf[diff_idx + 1 ..];
                }
                if (parent.eql(FullName{ .buf = file.package.? })) {
                    return fullTypeName.name().buf;
                }
            }

            var parent: ?FullName = fullTypeName.parent();
            const filePackage = FullName{ .buf = file.package.? };

            // iterate parents until we find a parent that matches the known_packages
            while (parent != null) {
                var it = ctx.known_packages.valueIterator();

                while (it.next()) |value| {

                    // it is in current package, return full name
                    if (filePackage.eql(parent.?)) {
                        const name = fullTypeName.buf[parent.?.buf.len + 1 ..];
                        return name;
                    }

                    // it is in different package. return fully qualified name including accessor
                    if (value.eql(parent.?)) {
                        const prop = try escapeFqn(allocator, parent.?.buf);
                        const name = fullTypeName.buf[prop.len + 1 ..];
                        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop, name });
                    }
                }

                parent = parent.?.parent();
            }

            std.debug.print("Unknown type: {s} from {s} in {s}\n", .{ fullTypeName.buf, parentFqn.buf, file.package.? });

            return try escapeFqn(allocator, field.type_name.?);
        }
        @panic("field has no type");
    }

    fn getFieldType(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        field: descriptor.FieldDescriptorProto,
        features: Features,
        is_union: bool,
    ) ![]const u8 {
        var prefix: []const u8 = "";
        var postfix: []const u8 = "";
        const repeated = isRepeated(field);
        const t = field.type.?;

        if (!repeated) {
            if (!is_union) {
                // look for optional types
                switch (t) {
                    .TYPE_MESSAGE, .TYPE_GROUP => {
                        // Check if the field type is self-referential
                        if (field.type_name) |type_name| {
                            const dep_name = type_name[1..]; // Remove leading dot
                            if (std.mem.eql(u8, dep_name, fqn.buf) or isAncestorFqn(dep_name, fqn.buf)) {
                                prefix = "?*";
                            } else {
                                prefix = "?";
                            }
                        } else {
                            prefix = "?";
                        }
                    },
                    else => if (hasExplicitPresence(field, features)) {
                        prefix = "?";
                    },
                }
            }
        } else {
            prefix = "std.ArrayList(";
            postfix = ")";
        }

        const infix: []const u8 = switch (t) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32 => "i32",
            .TYPE_UINT32, .TYPE_FIXED32 => "u32",
            .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => "i64",
            .TYPE_UINT64, .TYPE_FIXED64 => "u64",
            .TYPE_BOOL => "bool",
            .TYPE_DOUBLE => "f64",
            .TYPE_FLOAT => "f32",
            .TYPE_STRING, .TYPE_BYTES => "[]const u8",
            .TYPE_ENUM, .TYPE_MESSAGE, .TYPE_GROUP => try self.fieldTypeFqn(allocator, fqn, file, field),
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    fn getFieldDefault(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        field: descriptor.FieldDescriptorProto,
        features: Features,
        nullable: bool,
    ) !?[]const u8 {
        // All repeated fields, across proto2/proto3/editions, have a default
        // of empty. Repeated fields cannot be marked required (or optional)
        // in proto2.
        if (isRepeated(field)) return ".empty";

        // Fields with explicit presence are not set by default. Their custom
        // default value, if any, is exposed in `defaults` instead.
        if (nullable) return "null";

        // Implicit presence fields cannot declare default values; the zero
        // value of their type is used instead.
        if (features.field_presence == .IMPLICIT) {
            return switch (field.type.?) {
                .TYPE_SINT32,
                .TYPE_SFIXED32,
                .TYPE_INT32,
                .TYPE_UINT32,
                .TYPE_FIXED32,
                .TYPE_INT64,
                .TYPE_SINT64,
                .TYPE_SFIXED64,
                .TYPE_UINT64,
                .TYPE_FIXED64,
                .TYPE_FLOAT,
                .TYPE_DOUBLE,
                => "0",
                .TYPE_BOOL => "false",
                .TYPE_STRING, .TYPE_BYTES => "&.{}",
                // The first enumerator, which is zero for open enums. Closed
                // enums (possible as map values) may start at any number.
                .TYPE_ENUM => b: {
                    const e = self.enums.get(field.type_name.?) orelse break :b "@enumFromInt(0)";
                    const first = if (e.value.items.len > 0) e.value.items[0].number orelse 0 else 0;
                    if (first == 0) break :b "@enumFromInt(0)";
                    break :b try std.fmt.allocPrint(allocator, "@enumFromInt({})", .{first});
                },
                else => null,
            };
        }

        // Required fields have no default unless one is declared, forcing
        // them to be initialized.
        return try formatDefaultValue(allocator, field);
    }

    /// Formats the custom `[default = ...]` value of a field as Zig source.
    fn formatDefaultValue(allocator: std.mem.Allocator, field: descriptor.FieldDescriptorProto) !?[]const u8 {
        const default = field.default_value orelse return null;
        return switch (field.type.?) {
            .TYPE_SINT32,
            .TYPE_SFIXED32,
            .TYPE_INT32,
            .TYPE_UINT32,
            .TYPE_FIXED32,
            .TYPE_INT64,
            .TYPE_SINT64,
            .TYPE_SFIXED64,
            .TYPE_UINT64,
            .TYPE_FIXED64,
            .TYPE_BOOL,
            => default,
            .TYPE_FLOAT => if (std.mem.eql(u8, default, "inf"))
                "std.math.inf(f32)"
            else if (std.mem.eql(u8, default, "-inf"))
                "-std.math.inf(f32)"
            else if (std.mem.eql(u8, default, "nan"))
                "std.math.nan(f32)"
            else
                default,
            .TYPE_DOUBLE => if (std.mem.eql(u8, default, "inf"))
                "std.math.inf(f64)"
            else if (std.mem.eql(u8, default, "-inf"))
                "-std.math.inf(f64)"
            else if (std.mem.eql(u8, default, "nan"))
                "std.math.nan(f64)"
            else
                default,
            .TYPE_STRING, .TYPE_BYTES => if (default.len == 0)
                "&.{}"
            else
                try formatSliceEscapeImpl(allocator, default),
            .TYPE_ENUM => try std.mem.concat(allocator, u8, &.{ ".", default }),
            else => null,
        };
    }

    fn getFieldTypeDescriptor(
        _: *GenerationContext,
        allocator: std.mem.Allocator,
        field: descriptor.FieldDescriptorProto,
        features: Features,
    ) ![]const u8 {
        var prefix: []const u8 = "";

        var postfix: []const u8 = "";

        if (isRepeated(field)) {
            if (isPacked(field, features)) {
                prefix = ".{ .packed_repeated = ";
            } else {
                prefix = ".{ .repeated = ";
            }
            postfix = "}";
        }

        const infix: []const u8 = switch (field.type.?) {
            .TYPE_FLOAT => ".{ .scalar = .float }",
            .TYPE_DOUBLE => ".{ .scalar = .double }",
            .TYPE_FIXED32 => ".{ .scalar = .fixed32 }",
            .TYPE_SFIXED32 => ".{ .scalar = .sfixed32 }",
            .TYPE_FIXED64 => ".{ .scalar = .fixed64 }",
            .TYPE_SFIXED64 => ".{ .scalar = .sfixed64 }",
            .TYPE_ENUM => ".@\"enum\"",
            .TYPE_UINT32 => ".{ .scalar = .uint32 }",
            .TYPE_UINT64 => ".{ .scalar = .uint64 }",
            .TYPE_BOOL => ".{ .scalar = .bool }",
            .TYPE_INT32 => ".{ .scalar = .int32 }",
            .TYPE_INT64 => ".{ .scalar = .int64 }",
            .TYPE_SINT32 => ".{ .scalar = .sint32 }",
            .TYPE_SINT64 => ".{ .scalar = .sint64}",
            .TYPE_STRING => ".{ .scalar = .string }",
            .TYPE_BYTES => ".{ .scalar = .bytes }",
            .TYPE_MESSAGE, .TYPE_GROUP => ".submessage",
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    /// Formats the runtime features of a field that differ from the defaults
    /// of `protobuf.Features`, as a struct literal. Null if none differ.
    fn getFieldFeatures(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        message: descriptor.DescriptorProto,
        field: descriptor.FieldDescriptorProto,
        features: Features,
    ) !?[]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        if (self.isDelimited(message, field, features)) {
            try parts.append(allocator, ".message_encoding = .delimited");
        }
        if (field.type == .TYPE_STRING and features.utf8_validation == .VERIFY) {
            try parts.append(allocator, ".utf8_validation = .verify");
        }
        if (!isRepeated(field) and features.field_presence == .LEGACY_REQUIRED) {
            try parts.append(allocator, ".legacy_required = true");
        }
        if (parts.items.len == 0) return null;

        const joined = try std.mem.join(allocator, ", ", parts.items);
        return try std.fmt.allocPrint(allocator, ".{{ {s} }}", .{joined});
    }

    fn generateFieldDescriptor(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        message: descriptor.DescriptorProto,
        field: descriptor.FieldDescriptorProto,
        features: Features,
    ) !void {
        const name = try escapeName(allocator, field.name.?);
        const descStr = try self.getFieldTypeDescriptor(allocator, field, features);
        const line = if (try self.getFieldFeatures(allocator, message, field, features)) |featuresStr|
            try std.fmt.allocPrint(allocator, "        .{s} = fdf({?d}, {s}, {s}),\n", .{ name, field.number, descStr, featuresStr })
        else
            try std.fmt.allocPrint(allocator, "        .{s} = fd({?d}, {s}),\n", .{ name, field.number, descStr });
        try lines.append(allocator, line);
    }

    fn generateFieldDeclaration(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        field: descriptor.FieldDescriptorProto,
        features: Features,
    ) !void {
        const type_str = try self.getFieldType(allocator, fqn, file, field, features, false);
        const field_name = try escapeName(allocator, field.name.?);
        const nullable = type_str[0] == '?';

        if (try self.getFieldDefault(allocator, field, features, nullable)) |default_value| {
            try lines.append(
                allocator,
                try std.fmt.allocPrint(allocator, "    {s}: {s} = {s},\n", .{ field_name, type_str, default_value }),
            );
        } else {
            try lines.append(
                allocator,
                try std.fmt.allocPrint(allocator, "    {s}: {s},\n", .{ field_name, type_str }),
            );
        }
    }

    /// this function returns the amount of options available for a given "oneof" declaration
    ///
    /// since protobuf 3.14, optional values in proto3 are wrapped in a single-element
    /// oneof to enable optional behavior in most languages. since we have optional types
    /// in zig, we can not use it for a better end-user experience and for readability
    fn amountOfElementsInOneofUnion(_: *GenerationContext, message: descriptor.DescriptorProto, oneof_index: ?i32) u32 {
        if (oneof_index == null) return 0;

        var count: u32 = 0;
        for (message.field.items) |f| {
            if (oneof_index == f.oneof_index)
                count += 1;
        }

        return count;
    }

    fn generateMessages(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        /// Message declaring `messages`, null for top-level messages.
        parent: ?descriptor.DescriptorProto,
        messages: std.ArrayList(descriptor.DescriptorProto),
        root_path: []const i32,
        message_field_number: i32,
        /// Resolved features of the scope declaring `messages`.
        scope_features: Features,
    ) !void {
        for (messages.items, 0..) |message, message_i| {
            const m: descriptor.DescriptorProto = message;
            const messageFqn = try fqn.append(allocator, m.name.?);

            // WKT messages are re-exported from protobuf.wkt instead of being inlined.
            if (isWktMessage(messageFqn)) {
                // Only emit a top-level re-export (not for nested types, which live inside the WKT).
                var is_top_level_wkt = false;
                for (wkt_message_fqns) |wkt_fqn| {
                    if (std.mem.eql(u8, messageFqn.buf, wkt_fqn)) {
                        is_top_level_wkt = true;
                        break;
                    }
                }
                if (is_top_level_wkt) {
                    try lines.append(allocator, "\n");
                    try lines.append(
                        allocator,
                        try std.fmt.allocPrint(allocator, "pub const {s} = protobuf.wkt.{s};\n", .{ m.name.?, m.name.? }),
                    );
                }
                continue;
            }

            // Map entries are synthesized from their map field, and inherit
            // the features of that field rather than those of the scope.
            var message_features = scope_features.merge(if (m.options) |o| o.features else null);
            if (isMapEntry(m)) if (parent) |p| for (p.field.items) |pf| {
                const type_name = pf.type_name orelse continue;
                if (std.mem.eql(u8, type_name[1..], messageFqn.buf)) {
                    message_features = scope_features.forField(file, p, pf);
                }
            };

            // Build the path for this message: root_path + [message_field_number, message_i]
            var message_path: std.ArrayList(i32) = .empty;
            defer message_path.deinit(allocator);
            try message_path.appendSlice(allocator, root_path);
            try message_path.append(allocator, message_field_number);
            try message_path.append(allocator, @intCast(message_i));

            try lines.append(allocator, "\n");

            // Add leading comment if available
            if (SourceCodeInfo.getRepeatedFieldLocation(
                file,
                root_path,
                message_field_number,
                message_i,
            )) |loc| {
                if (loc.leading_comments) |leading_comments| {
                    try SourceCodeInfo.appendComment(allocator, lines, leading_comments);
                }
            }

            try lines.append(
                allocator,
                try std.fmt.allocPrint(allocator, "pub const {s} = struct {{\n", .{m.name.?}),
            );

            // Oneof declarations of nested messages are referenced through
            // the message path, as an enclosing message may declare a oneof
            // with the same name, which Zig would report as ambiguous.
            const union_scope: []const u8 = if (parent == null) "" else try std.mem.concat(
                allocator,
                u8,
                &.{ messageFqn.buf[file.package.?.len + 1 ..], "." },
            );

            // append all fields that are not part of a oneof
            for (m.field.items) |f| {
                if (f.oneof_index == null or self.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try self.generateFieldDeclaration(allocator, lines, messageFqn, file, f, message_features.forField(file, m, f));
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                const union_element_count = self.amountOfElementsInOneofUnion(m, @as(i32, @intCast(i)));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?;
                    try lines.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        // Oneof fields across proto2, proto3, and editions
                        // are "not set" by default, which is represented as
                        // the null value here.
                        "    {s}: ?{s}{s}_union = null,\n",
                        .{ try escapeName(allocator, oneof_name), union_scope, oneof_name },
                    ));
                }
            }
            if (m.extension_range.items.len > 0) {
                // Raw wire records of the extensions, see `protobuf.Extension`.
                try lines.append(allocator, "    _extensions: []const u8 = &.{},\n");
            }
            if (self.shouldPreserveUnknownFields(m)) {
                try lines.append(allocator, "    _unknown_fields: []const u8 = &.{},\n");
            }

            // then print the oneof declarations
            for (m.oneof_decl.items, 0..) |oneof, i| {
                // only emit unions that have more than one element
                const union_element_count = self.amountOfElementsInOneofUnion(m, @as(i32, @intCast(i)));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?;

                    try lines.append(allocator, try std.fmt.allocPrint(allocator,
                        \\
                        \\    pub const _{s}_case = enum {{
                        \\
                    , .{oneof_name}));

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @as(i32, @intCast(i))) {
                            const name = try escapeName(allocator, f.name.?);
                            try lines.append(allocator, try std.fmt.allocPrint(allocator, "      {s},\n", .{name}));
                        }
                    }

                    try lines.append(allocator, try std.fmt.allocPrint(allocator,
                        \\    }};
                        \\    pub const {s}_union = union({s}_{s}_case) {{
                        \\
                    , .{ oneof_name, union_scope, oneof_name }));

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @as(i32, @intCast(i))) {
                            const name = try escapeName(allocator, f.name.?);
                            const typeStr = try self.getFieldType(allocator, messageFqn, file, f, message_features.forField(file, m, f), true);
                            try lines.append(allocator, try std.fmt.allocPrint(
                                allocator,
                                "      {s}: {s},\n",
                                .{ name, typeStr },
                            ));
                        }
                    }

                    try lines.append(allocator,
                        \\    pub const _desc_table  = .{
                        \\
                    );

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @as(i32, @intCast(i))) {
                            try self.generateFieldDescriptor(allocator, lines, m, f, message_features.forField(file, m, f));
                        }
                    }

                    try lines.append(allocator,
                        \\      };
                        \\    };
                        \\
                    );
                }
            }

            // field descriptors
            try lines.append(allocator,
                \\
                \\    pub const _desc_table = .{
                \\
            );

            // first print fields
            for (m.field.items) |f| {
                if (f.oneof_index == null or self.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try self.generateFieldDescriptor(allocator, lines, m, f, message_features.forField(file, m, f));
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                // only emit unions that have more than one element
                const union_element_count = self.amountOfElementsInOneofUnion(m, @as(i32, @intCast(i)));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?;
                    try lines.append(
                        allocator,
                        try std.fmt.allocPrint(
                            allocator,
                            "    .{s} = fd(null, .{{ .oneof  = {s}{s}_union }}),\n",
                            .{ try escapeName(allocator, oneof_name), union_scope, oneof_name },
                        ),
                    );
                }
            }

            try lines.append(allocator,
                \\    };
                \\
            );

            try self.generateDefaults(allocator, lines, messageFqn, file, m, message_features);
            try generateExtensionsInfo(allocator, lines, m);

            // For nested enums, root_path is the message's path and field number is 4 (enum_type in DescriptorProto)
            try self.generateEnums(allocator, lines, messageFqn, file, m.enum_type, message_path.items, 4, message_features);
            // For nested messages, root_path is the message's path and field number is 3 (nested_type in DescriptorProto)
            try self.generateMessages(allocator, lines, messageFqn, file, m, m.nested_type, message_path.items, 3, message_features);
            try self.generateExtensions(allocator, lines, messageFqn, file, m.extension, message_features);

            try lines.append(allocator, try std.fmt.allocPrint(allocator,
                \\
                \\    /// Encodes the message to the writer
                \\    /// The allocator is used to generate submessages internally.
                \\    /// Hence, an ArenaAllocator is a preferred choice if allocations are a bottleneck.
                \\    pub fn encode(
                \\        self: @This(),
                \\        writer: *std.Io.Writer,
                \\        allocator: std.mem.Allocator,
                \\    ) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {{
                \\        return protobuf.encode(writer, allocator, self);
                \\    }}
                \\
                \\    /// Decodes the message from the bytes read from the reader.
                \\    pub fn decode(
                \\        reader: *std.Io.Reader,
                \\        allocator: std.mem.Allocator,
                \\    ) (protobuf.DecodingError || std.Io.Reader.Error || std.mem.Allocator.Error)!@This() {{
                \\        return protobuf.decode(@This(), reader, allocator);
                \\    }}
                \\
                \\    /// Streaming pull-decoder: walks a `std.Io.Reader` one wire
                \\    /// field at a time without allocating. See `src/stream.zig`.
                \\    pub const StreamDecoder = protobuf.StreamDecoder(@This());
                \\
                \\    /// Deinitializes and frees the memory associated with the message.
                \\    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {{
                \\        return protobuf.deinit(allocator, self);
                \\    }}
                \\
                \\    /// Duplicates the message.
                \\    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {{
                \\        return protobuf.dupe(@This(), self, allocator);
                \\    }}
                \\
                \\    /// Decodes the message from the JSON string.
                \\    pub fn jsonDecode(
                \\        input: []const u8,
                \\        options: std.json.ParseOptions,
                \\        allocator: std.mem.Allocator,
                \\    ) !std.json.Parsed(@This()) {{
                \\        return protobuf.json.decode(@This(), input, options, allocator);
                \\    }}
                \\  
                \\    /// Encodes the message to a JSON string.
                \\    pub fn jsonEncode(
                \\        self: @This(),
                \\        options: std.json.Stringify.Options,
                \\        pb_options: protobuf.json.Options,
                \\        allocator: std.mem.Allocator,
                \\    ) ![]const u8 {{
                \\        return protobuf.json.encode(self, options, pb_options, allocator);
                \\    }}
                \\
                \\    /// This method is used by std.json
                \\    /// internally for deserialization. DO NOT RENAME!
                \\    pub fn jsonParse(
                \\        allocator: std.mem.Allocator,
                \\        source: anytype,
                \\        options: std.json.ParseOptions,
                \\    ) !@This() {{
                \\        return protobuf.json.parse(@This(), allocator, source, options);
                \\    }}
                \\
                \\}};
                \\
            , .{}));
        }
    }

    /// Emits `defaults`, holding the custom `[default = ...]` values of the
    /// fields with explicit presence. Such fields are `null` when unset, in
    /// which case their value is the one declared here.
    fn generateDefaults(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        message: descriptor.DescriptorProto,
        message_features: Features,
    ) !void {
        var emitted = false;
        for (message.field.items) |f| {
            if (isRepeated(f) or f.default_value == null) continue;
            const features = message_features.forField(file, message, f);
            if (!hasExplicitPresence(f, features)) continue;
            const value = try formatDefaultValue(allocator, f) orelse continue;

            if (!emitted) {
                if (definesDefaultsMember(message)) {
                    self.res.@"error" = try std.fmt.allocPrint(
                        allocator,
                        "ERROR {s} declares a member named \"defaults\", which conflicts with the generated `defaults` declaration\n",
                        .{fqn.buf},
                    );
                    return;
                }
                try lines.append(allocator,
                    \\
                    \\    /// Default values of fields that are `null` when not set.
                    \\    pub const defaults = struct {
                    \\
                );
                emitted = true;
            }
            // Non-optional type of the field, as used within unions.
            const type_str = try self.getFieldType(allocator, fqn, file, f, features, true);
            try lines.append(allocator, try std.fmt.allocPrint(
                allocator,
                // Unlike fields, declarations may not shadow primitives.
                "        pub const {f}: {s} = {s};\n",
                .{ std.zig.fmtId(f.name.?), type_str, value },
            ));
        }
        if (emitted) try lines.append(allocator, "    };\n");
    }

    /// Emits the extensions declared in a scope (a file or a message) as
    /// `protobuf.Extension` declarations, and records them for the
    /// `extensions` declaration of their package.
    fn generateExtensions(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        scope_fqn: FullName,
        file: descriptor.FileDescriptorProto,
        extensions: std.ArrayList(descriptor.FieldDescriptorProto),
        scope_features: Features,
    ) !void {
        const package = file.package.?;
        for (extensions.items) |ext| {
            // Extensions resolve their features from their declaration scope.
            // Singular extensions always have explicit presence.
            var features = scope_features.forField(file, .{}, ext);
            if (!isRepeated(ext)) features.field_presence = .EXPLICIT;

            var extendee_field = ext;
            extendee_field.type_name = ext.extendee;
            const extendee = try self.fieldTypeFqn(allocator, scope_fqn, file, extendee_field);
            // The value is stored apart from its scope, so a message type is
            // never self-referential and needs no pointer.
            const element_type = try self.getFieldType(allocator, scope_fqn, file, ext, features, true);
            const value_type = if (isRepeated(ext))
                element_type
            else
                try std.mem.concat(allocator, u8, &.{ "?", element_type });
            const ftype = try self.getFieldTypeDescriptor(allocator, ext, features);
            const field_desc = if (try self.getFieldFeatures(allocator, .{}, ext, features)) |fs|
                try std.fmt.allocPrint(allocator, "fdf({?d}, {s}, {s})", .{ ext.number, ftype, fs })
            else
                try std.fmt.allocPrint(allocator, "fd({?d}, {s})", .{ ext.number, ftype });
            const default = if (isRepeated(ext)) "null" else if (try formatDefaultValue(allocator, ext)) |value|
                try std.fmt.allocPrint(allocator, "@as({s}, {s})", .{
                    try self.getFieldType(allocator, scope_fqn, file, ext, features, true),
                    value,
                })
            else
                "null";

            try lines.append(allocator, try std.fmt.allocPrint(
                allocator,
                "\npub const {f} = protobuf.Extension({s}, {s}, {s}, \"{s}.{s}\", {s});\n",
                .{ std.zig.fmtId(ext.name.?), extendee, value_type, field_desc, scope_fqn.buf, ext.name.?, default },
            ));

            // Reference relative to the package, for the `extensions` list.
            const reference = if (scope_fqn.buf.len == package.len)
                try std.fmt.allocPrint(allocator, "{f}", .{std.zig.fmtId(ext.name.?)})
            else
                try std.fmt.allocPrint(allocator, "{s}.{f}", .{ scope_fqn.buf[package.len + 1 ..], std.zig.fmtId(ext.name.?) });
            const entry = try self.package_extensions.getOrPut(package);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, reference);
        }
    }

    /// Emits `_extensions_info` for a message with extension ranges: the
    /// ranges, which decide the fields kept as extensions when decoding, and
    /// whether the extensions use the legacy MessageSet format.
    fn generateExtensionsInfo(
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        message: descriptor.DescriptorProto,
    ) !void {
        if (message.extension_range.items.len == 0) return;
        try lines.append(allocator,
            \\
            \\    /// Extension ranges `[start, end)`, and whether the extensions are
            \\    /// encoded in the legacy MessageSet format.
            \\    pub const _extensions_info = .{
            \\        .ranges = .{
        );
        for (message.extension_range.items) |range| {
            try lines.append(allocator, try std.fmt.allocPrint(
                allocator,
                " .{{ {?d}, {?d} }},",
                .{ range.start, range.end },
            ));
        }
        const message_set = if (message.options) |o| o.message_set_wire_format orelse false else false;
        try lines.append(allocator, try std.fmt.allocPrint(
            allocator,
            " }},\n        .message_set = {},\n    }};\n",
            .{message_set},
        ));
    }

    /// Returns the `extensions` declaration listing the extensions of
    /// `package`, or null if it declares none.
    fn packageExtensionsDeclaration(self: *GenerationContext, allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
        const references = self.package_extensions.get(package) orelse return null;

        // The declaration shares the top-level scope of the package.
        for (self.req.proto_file.items) |file| {
            if (!std.mem.eql(u8, file.package.?, package)) continue;
            var clash = false;
            for (file.message_type.items) |m| clash = clash or std.mem.eql(u8, m.name.?, "extensions");
            for (file.enum_type.items) |e| clash = clash or std.mem.eql(u8, e.name.?, "extensions");
            for (file.extension.items) |x| clash = clash or std.mem.eql(u8, x.name.?, "extensions");
            for (file.service.items) |s| clash = clash or std.mem.eql(u8, s.name.?, "extensions");
            if (clash) {
                self.res.@"error" = try std.fmt.allocPrint(
                    allocator,
                    "ERROR package {s} declares a member named \"extensions\", which conflicts with the generated `extensions` declaration\n",
                    .{package},
                );
                return null;
            }
        }

        return try std.fmt.allocPrint(
            allocator,
            "\n/// Extensions declared in this package, for `protobuf.ExtensionRegistry.init`.\npub const extensions = .{{ {s} }};\n",
            .{try std.mem.join(allocator, ", ", references.items)},
        );
    }

    /// Whether a field, oneof, nested message or nested enum of `message` is
    /// named `defaults`, as Zig forbids members sharing a name.
    fn definesDefaultsMember(message: descriptor.DescriptorProto) bool {
        for (message.field.items) |f| if (std.mem.eql(u8, f.name.?, "defaults")) return true;
        for (message.oneof_decl.items) |o| if (std.mem.eql(u8, o.name.?, "defaults")) return true;
        for (message.nested_type.items) |m| if (std.mem.eql(u8, m.name.?, "defaults")) return true;
        for (message.enum_type.items) |e| if (std.mem.eql(u8, e.name.?, "defaults")) return true;
        for (message.extension.items) |x| if (std.mem.eql(u8, x.name.?, "defaults")) return true;
        return false;
    }

    /// Analyzes message dependencies to detect self-referential messages
    fn analyzeMessageDependencies(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        fqn: FullName,
        message: descriptor.DescriptorProto,
    ) !bool {
        const message_name = message.name.?;
        const full_message_name = fqn.buf; // Use package name directly
        var deps: std.ArrayList([]const u8) = .empty;

        // Check fields for message types
        for (message.field.items) |field| {
            if (field.type) |t| {
                if (t == .TYPE_MESSAGE) {
                    if (field.type_name) |type_name| {
                        const raw_type = type_name;
                        const dep_name = raw_type[1..]; // Remove leading dot
                        try deps.append(allocator, dep_name);

                        // Check for direct self-reference by comparing the last part of the type name
                        const last_dot = std.mem.lastIndexOf(u8, dep_name, ".");
                        const simple_name = if (last_dot) |idx| dep_name[idx + 1 ..] else dep_name;

                        if (std.mem.eql(u8, simple_name, message_name)) {
                            return true;
                        }
                    }
                }
            }
        }

        // Store dependencies for this message
        try self.message_deps.put(full_message_name, deps);

        // Check if this message is self-referential (directly or indirectly)
        var visited: std.StringHashMap(bool) = .init(allocator);
        defer visited.deinit();
        return self.isMessageSelfReferential(full_message_name, &visited);
    }

    /// Recursively checks if a message is self-referential
    fn isMessageSelfReferential(
        self: *GenerationContext,
        message_name: []const u8,
        visited: *std.StringHashMap(bool),
    ) bool {
        if (visited.get(message_name)) |_| {
            return true; // Found a cycle
        }

        if (self.message_deps.get(message_name)) |deps| {
            visited.put(message_name, true) catch return false;
            defer _ = visited.remove(message_name);

            for (deps.items) |dep| {
                const last_dot = std.mem.lastIndexOf(u8, dep, ".");
                const simple_name = if (last_dot) |idx| dep[idx + 1 ..] else dep;
                const last_dot_msg = std.mem.lastIndexOf(u8, message_name, ".");
                const msg_simple_name = if (last_dot_msg) |idx| message_name[idx + 1 ..] else message_name;

                // Check for self-reference by comparing simple names
                if (std.mem.eql(u8, simple_name, msg_simple_name)) {
                    return true;
                }
                // Also check for indirect cycles
                if (self.isMessageSelfReferential(dep, visited)) {
                    return true;
                }
            }
        }

        return false;
    }

    fn generateServices(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        services: std.ArrayList(descriptor.ServiceDescriptorProto),
        root_path: []const i32,
        service_field_number: i32,
    ) !void {
        for (services.items, 0..) |service, service_i| {
            try lines.append(allocator, "\n");

            // Add service-level leading comment if available
            if (SourceCodeInfo.getRepeatedFieldLocation(
                file,
                root_path,
                service_field_number,
                service_i,
            )) |loc| {
                if (loc.leading_comments) |leading_comments| {
                    try SourceCodeInfo.appendComment(allocator, lines, leading_comments);
                }
            }

            const service_name = service.name.?;

            // Generate single VTable function
            try lines.append(
                allocator,
                try std.fmt.allocPrint(
                    allocator,
                    "pub fn {s}(comptime UserDataType: type, comptime ErrorSet: type) type {{\n",
                    .{service_name},
                ),
            );
            try lines.append(allocator, "    return struct {\n");

            // Add service metadata
            try lines.append(
                allocator,
                try std.fmt.allocPrint(
                    allocator,
                    "        pub const package = \"{s}\";\n",
                    .{fqn.buf},
                ),
            );
            try lines.append(
                allocator,
                try std.fmt.allocPrint(
                    allocator,
                    "        pub const service_name = \"{s}\";\n\n",
                    .{service_name},
                ),
            );

            // Generate vtable fields (function pointers only)
            try self.generateVTableFields(
                allocator,
                lines,
                fqn,
                file,
                service,
                root_path,
                service_field_number,
                service_i,
            );

            try lines.append(allocator, "    };\n");
            try lines.append(allocator, "}\n");
        }
    }

    fn generateVTableFields(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]const u8),
        fqn: FullName,
        file: descriptor.FileDescriptorProto,
        service: descriptor.ServiceDescriptorProto,
        root_path: []const i32,
        service_field_number: i32,
        service_index: usize,
    ) !void {
        // Build the path for methods within this service
        var method_root_path: std.ArrayList(i32) = .empty;
        defer method_root_path.deinit(allocator);
        try method_root_path.appendSlice(allocator, root_path);
        try method_root_path.append(allocator, service_field_number);
        try method_root_path.append(allocator, @intCast(service_index));

        for (service.method.items, 0..) |method, method_i| {
            // Add method-level leading comment if available
            if (SourceCodeInfo.getRepeatedFieldLocation(
                file,
                method_root_path.items,
                2, // Field number for 'method' in ServiceDescriptorProto
                method_i,
            )) |loc| {
                if (loc.leading_comments) |leading_comments| {
                    try SourceCodeInfo.appendComment(allocator, lines, leading_comments);
                }
            }

            const method_name = method.name.?;
            const input_type = try self.resolveServiceTypeName(allocator, fqn, file, method.input_type.?);
            const output_type = try self.resolveServiceTypeName(allocator, fqn, file, method.output_type.?);
            const client_streaming = method.client_streaming orelse false;
            const server_streaming = method.server_streaming orelse false;

            // Generate function pointer signature based on streaming pattern
            const fn_sig = try self.generateMethodSignature(
                allocator,
                input_type,
                output_type,
                client_streaming,
                server_streaming,
            );

            try lines.append(
                allocator,
                try std.fmt.allocPrint(allocator, "        {s}: {s},\n", .{ method_name, fn_sig }),
            );
        }
    }

    fn generateMethodSignature(
        _: *GenerationContext,
        allocator: std.mem.Allocator,
        input_type: []const u8,
        output_type: []const u8,
        client_streaming: bool,
        server_streaming: bool,
    ) ![]const u8 {
        if (!client_streaming and !server_streaming) {
            // Unary: *const fn(userdata: *UserDataType, request: Request) ErrorSet!Response
            return try std.fmt.allocPrint(
                allocator,
                "*const fn(userdata: *UserDataType, request: {s}) ErrorSet!{s}",
                .{ input_type, output_type },
            );
        } else if (!client_streaming and server_streaming) {
            // Server streaming: *const fn(userdata: *UserDataType, request: Request, writer_queue: *std.Io.Queue(Response)) ErrorSet!void
            return try std.fmt.allocPrint(
                allocator,
                "*const fn(userdata: *UserDataType, request: {s}, writer_queue: *std.Io.Queue({s})) ErrorSet!void",
                .{ input_type, output_type },
            );
        } else if (client_streaming and !server_streaming) {
            // Client streaming: *const fn(userdata: *UserDataType, reader_queue: *std.Io.Queue(Request)) ErrorSet!Response
            return try std.fmt.allocPrint(
                allocator,
                "*const fn(userdata: *UserDataType, reader_queue: *std.Io.Queue({s})) ErrorSet!{s}",
                .{ input_type, output_type },
            );
        } else {
            // Bidirectional streaming: *const fn(userdata: *UserDataType, reader_queue: *std.Io.Queue(Request), writer_queue: *std.Io.Queue(Response)) ErrorSet!void
            return try std.fmt.allocPrint(
                allocator,
                "*const fn(userdata: *UserDataType, reader_queue: *std.Io.Queue({s}), writer_queue: *std.Io.Queue({s})) ErrorSet!void",
                .{ input_type, output_type },
            );
        }
    }

    fn resolveServiceTypeName(
        self: *GenerationContext,
        allocator: std.mem.Allocator,
        _: FullName,
        file: descriptor.FileDescriptorProto,
        type_name: []const u8,
    ) ![]const u8 {
        // Type names in services come with a leading dot (e.g., ".package.MessageType")
        // We need to strip the dot and resolve relative to the current package
        if (type_name.len == 0 or type_name[0] != '.') {
            return type_name; // No leading dot, return as-is
        }

        const fullTypeName = FullName{ .buf = type_name[1..] }; // Strip leading dot

        // Check if it's in the same package
        const filePackage = FullName{ .buf = file.package.? };
        if (fullTypeName.parent()) |parent| {
            if (parent.eql(filePackage)) {
                // Same package, return just the type name
                return fullTypeName.name().buf;
            }
        }

        // Check if it's in a known imported package
        var parent: ?FullName = fullTypeName.parent();
        while (parent != null) {
            var it = self.known_packages.valueIterator();
            while (it.next()) |value| {
                if (value.eql(parent.?)) {
                    // Found in an imported package
                    const prop = try escapeFqn(allocator, parent.?.buf);
                    const name = fullTypeName.buf[parent.?.buf.len + 1 ..];
                    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop, name });
                }
            }
            parent = parent.?.parent();
        }

        // If not found in any known package, return the full name
        return fullTypeName.buf;
    }

    fn shouldPreserveUnknownFields(self: *GenerationContext, message: descriptor.DescriptorProto) bool {
        if (message.options) |options| {
            if (options.map_entry orelse false) return false;
        }

        return self.preserve_unknown_fields;
    }
};

const FeatureSet = descriptor.FeatureSet;

/// Oldest and newest editions this generator supports. proto2 and proto3 are
/// handled as the legacy editions they correspond to. Editions 2024 and 2026
/// only change features with source retention (naming style, symbol
/// visibility, proto limits), which protoc enforces itself, so the features
/// resolved here are the same from edition 2023 onwards.
const minimum_edition: descriptor.Edition = .EDITION_PROTO2;
const maximum_edition: descriptor.Edition = .EDITION_2026;

/// Fully resolved editions features of a file, message, enum or field.
///
/// protoc only hands plugins the features that were set explicitly, so every
/// element is resolved here: the edition defaults are overridden by the file,
/// then by each enclosing message, then by the element itself.
const Features = struct {
    field_presence: FeatureSet.FieldPresence,
    enum_type: FeatureSet.EnumType,
    repeated_field_encoding: FeatureSet.RepeatedFieldEncoding,
    utf8_validation: FeatureSet.Utf8Validation,
    message_encoding: FeatureSet.MessageEncoding,

    /// Feature defaults of an edition, as specified by descriptor.proto.
    fn defaults(edition: descriptor.Edition) Features {
        const e = @intFromEnum(edition);
        if (e < @intFromEnum(descriptor.Edition.EDITION_PROTO3)) return .{
            .field_presence = .EXPLICIT,
            .enum_type = .CLOSED,
            .repeated_field_encoding = .EXPANDED,
            .utf8_validation = .NONE,
            .message_encoding = .LENGTH_PREFIXED,
        };
        return .{
            .field_presence = if (edition == .EDITION_PROTO3) .IMPLICIT else .EXPLICIT,
            .enum_type = .OPEN,
            .repeated_field_encoding = .PACKED,
            .utf8_validation = .VERIFY,
            .message_encoding = .LENGTH_PREFIXED,
        };
    }

    /// Resolved features at the top-level scope of a file.
    fn forFile(file: descriptor.FileDescriptorProto) Features {
        const options_features = if (file.options) |o| o.features else null;
        return defaults(fileEdition(file)).merge(options_features);
    }

    /// Returns the features with the explicitly set ones in `set` applied.
    fn merge(self: Features, set: ?FeatureSet) Features {
        var result = self;
        const s = set orelse return result;
        if (s.field_presence) |v| if (v != .FIELD_PRESENCE_UNKNOWN) {
            result.field_presence = v;
        };
        if (s.enum_type) |v| if (v != .ENUM_TYPE_UNKNOWN) {
            result.enum_type = v;
        };
        if (s.repeated_field_encoding) |v| if (v != .REPEATED_FIELD_ENCODING_UNKNOWN) {
            result.repeated_field_encoding = v;
        };
        if (s.utf8_validation) |v| if (v != .UTF8_VALIDATION_UNKNOWN) {
            result.utf8_validation = v;
        };
        if (s.message_encoding) |v| if (v != .MESSAGE_ENCODING_UNKNOWN) {
            result.message_encoding = v;
        };
        return result;
    }

    /// Resolved features of `field`, declared in `message` whose resolved
    /// features are `self`.
    fn forField(
        self: Features,
        file: descriptor.FileDescriptorProto,
        message: descriptor.DescriptorProto,
        field: descriptor.FieldDescriptorProto,
    ) Features {
        var result = self;
        if (field.oneof_index) |i| {
            const oneof = message.oneof_decl.items[@intCast(i)];
            if (oneof.options) |o| result = result.merge(o.features);
        }
        if (field.options) |o| result = result.merge(o.features);

        // proto2 and proto3 express these features with dedicated syntax.
        if (!std.mem.eql(u8, file.syntax orelse "proto2", "editions")) {
            if (field.label == .LABEL_REQUIRED) result.field_presence = .LEGACY_REQUIRED;
            if (field.proto3_optional orelse false) result.field_presence = .EXPLICIT;
            if (field.type == .TYPE_GROUP) result.message_encoding = .DELIMITED;
            if (field.options) |o| if (o.@"packed") |p| {
                result.repeated_field_encoding = if (p) .PACKED else .EXPANDED;
            };
        }

        // The key and value of a map entry are always considered present, a
        // missing one meaning its zero value.
        if (isMapEntry(message)) result.field_presence = .IMPLICIT;
        return result;
    }
};

fn isMapEntry(message: descriptor.DescriptorProto) bool {
    const options = message.options orelse return false;
    return options.map_entry orelse false;
}

/// Edition of a file, with proto2 and proto3 mapped to their legacy editions.
fn fileEdition(file: descriptor.FileDescriptorProto) descriptor.Edition {
    const syntax = file.syntax orelse "proto2";
    if (std.mem.eql(u8, syntax, "editions")) return file.edition orelse .EDITION_UNKNOWN;
    if (std.mem.eql(u8, syntax, "proto3")) return .EDITION_PROTO3;
    return .EDITION_PROTO2;
}

fn packageToFileName(package: []const u8, output: []u8) []const u8 {
    const result_len = package.len + ".pb.zig".len;
    std.debug.assert(output.len >= result_len);
    for (package, output[0..package.len]) |c, *dest_c| {
        dest_c.* = if (c == '.' or c == '\\') '/' else c;
    }
    @memcpy(output[package.len..result_len], ".pb.zig");
    return output[0..result_len];
}

fn escapeFqn(allocator: std.mem.Allocator, n: []const u8) ![]const u8 {
    var r: []u8 = try allocator.alloc(u8, n.len);
    for (n, 0..) |byte, i| {
        r[i] = switch (byte) {
            '.', '/', '\\' => '_',
            else => byte,
        };
    }
    return r;
}

fn isRepeated(field: descriptor.FieldDescriptorProto) bool {
    return (field.label orelse return false) == .LABEL_REPEATED;
}

fn isAncestorFqn(ancestor: []const u8, descendant: []const u8) bool {
    return descendant.len > ancestor.len and
        std.mem.startsWith(u8, descendant, ancestor) and
        descendant[ancestor.len] == '.';
}

fn isScalarNumeric(t: descriptor.FieldDescriptorProto.Type) bool {
    return switch (t) {
        .TYPE_DOUBLE,
        .TYPE_FLOAT,
        .TYPE_INT32,
        .TYPE_INT64,
        .TYPE_UINT32,
        .TYPE_UINT64,
        .TYPE_SINT32,
        .TYPE_SINT64,
        .TYPE_FIXED32,
        .TYPE_FIXED64,
        .TYPE_SFIXED32,
        .TYPE_SFIXED64,
        .TYPE_BOOL,
        .TYPE_ENUM,
        => true,
        else => false,
    };
}

fn isPacked(field: descriptor.FieldDescriptorProto, features: Features) bool {
    // Only repeated scalar numeric fields can be packed.
    if (!isScalarNumeric(field.type orelse return false)) return false;
    return features.repeated_field_encoding == .PACKED;
}

/// Whether a singular, non-message field tracks presence, in which case it is
/// generated as an optional (`?T`) field.
fn hasExplicitPresence(field: descriptor.FieldDescriptorProto, features: Features) bool {
    // Fields of a oneof always have explicit presence.
    if (field.oneof_index != null) return true;
    return features.field_presence == .EXPLICIT;
}

pub fn formatSliceEscapeImpl(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try writer.writer.print("\"{f}\"", .{std.zig.fmtString(str)});

    return try writer.toOwnedSlice();
}

test "self referential" {
    _ = &GenerationContext.isMessageSelfReferential;
    _ = &GenerationContext.analyzeMessageDependencies;
}
