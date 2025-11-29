const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("protobuf", .{});
    const abseil_dep = b.dependency(
        "abseil",
        .{ .target = target, .optimize = optimize },
    );

    const upb = b.addLibrary(.{
        .name = "upb",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    upb.addIncludePath(upstream.path(""));
    upb.addIncludePath(upstream.path("src"));
    upb.addIncludePath(upstream.path("third_party/utf8_range"));
    upb.addIncludePath(upstream.path("upb/reflection/stage0"));
    upb.installHeadersDirectory(
        upstream.path("upb/reflection/stage0"),
        "",
        .{ .include_extensions = &.{".h"} },
    );
    upb.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = upb_srcs,
        .language = .c,
    });
    b.installArtifact(upb);

    const utf8_range = b.addLibrary(.{
        .name = "utf8_range",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    utf8_range.addIncludePath(upstream.path("third_party/utf8_range"));
    upb.installHeadersDirectory(
        upstream.path("third_party/utf8_range"),
        "",
        .{ .include_extensions = &.{".h"} },
    );
    utf8_range.addCSourceFiles(.{
        .root = upstream.path("third_party/utf8_range"),
        .files = utf8_range_srcs,
        .language = .cpp,
    });
    b.installArtifact(utf8_range);

    const libprotobuf = b.addLibrary(.{
        .name = "libprotobuf",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    libprotobuf.linkLibrary(abseil_dep.artifact("abseil"));
    libprotobuf.linkLibrary(utf8_range);
    libprotobuf.linkLibrary(upb);
    libprotobuf.addIncludePath(upstream.path(""));
    libprotobuf.addIncludePath(upstream.path("src"));
    libprotobuf.installHeadersDirectory(
        upstream.path("src"),
        "",
        .{ .include_extensions = &.{ ".h", ".proto" } },
    );
    libprotobuf.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = libprotobuf_srcs,
        .language = .cpp,
    });
    b.installArtifact(libprotobuf);

    const libprotoc = b.addLibrary(.{
        .name = "libprotoc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    libprotoc.linkLibrary(libprotobuf);
    libprotoc.linkLibrary(utf8_range);
    libprotoc.linkLibrary(upb);
    libprotoc.linkLibrary(abseil_dep.artifact("abseil"));
    libprotoc.addIncludePath(upstream.path(""));
    libprotoc.addIncludePath(upstream.path("src"));
    libprotoc.addIncludePath(upstream.path("third_party/utf8_range"));
    libprotoc.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = libprotoc_srcs,
        .language = .cpp,
    });
    b.installArtifact(libprotoc);

    const protoc = b.addExecutable(.{
        .name = "protoc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    protoc.linkLibrary(libprotoc);
    protoc.linkLibrary(libprotobuf);
    protoc.linkLibrary(utf8_range);
    protoc.linkLibrary(abseil_dep.artifact("abseil"));
    protoc.addIncludePath(upstream.path("src"));
    protoc.addIncludePath(upstream.path("third_party/utf8_range"));
    protoc.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = protoc_srcs,
        .language = .cpp,
    });

    b.installArtifact(protoc);
}

const utf8_range_srcs: []const []const u8 = &.{
    "utf8_range.c",
};

const libprotobuf_srcs: []const []const u8 = &.{
    "src/google/protobuf/any.pb.cc",
    "src/google/protobuf/api.pb.cc",
    "src/google/protobuf/duration.pb.cc",
    "src/google/protobuf/empty.pb.cc",
    "src/google/protobuf/field_mask.pb.cc",
    "src/google/protobuf/source_context.pb.cc",
    "src/google/protobuf/struct.pb.cc",
    "src/google/protobuf/timestamp.pb.cc",
    "src/google/protobuf/type.pb.cc",
    "src/google/protobuf/wrappers.pb.cc",
    "src/google/protobuf/any.cc",
    "src/google/protobuf/any_lite.cc",
    "src/google/protobuf/arena.cc",
    "src/google/protobuf/arena_align.cc",
    "src/google/protobuf/arenastring.cc",
    "src/google/protobuf/arenaz_sampler.cc",
    "src/google/protobuf/compiler/importer.cc",
    "src/google/protobuf/compiler/parser.cc",
    "src/google/protobuf/cpp_features.pb.cc",
    "src/google/protobuf/descriptor.cc",
    "src/google/protobuf/descriptor.pb.cc",
    "src/google/protobuf/descriptor_database.cc",
    "src/google/protobuf/dynamic_message.cc",
    "src/google/protobuf/extension_set.cc",
    "src/google/protobuf/extension_set_heavy.cc",
    "src/google/protobuf/feature_resolver.cc",
    "src/google/protobuf/generated_enum_util.cc",
    "src/google/protobuf/generated_message_bases.cc",
    "src/google/protobuf/generated_message_reflection.cc",
    "src/google/protobuf/generated_message_tctable_full.cc",
    "src/google/protobuf/generated_message_tctable_gen.cc",
    "src/google/protobuf/generated_message_tctable_lite.cc",
    "src/google/protobuf/generated_message_util.cc",
    "src/google/protobuf/implicit_weak_message.cc",
    "src/google/protobuf/inlined_string_field.cc",
    "src/google/protobuf/internal_feature_helper.cc",
    "src/google/protobuf/io/coded_stream.cc",
    "src/google/protobuf/io/gzip_stream.cc",
    "src/google/protobuf/io/io_win32.cc",
    "src/google/protobuf/io/printer.cc",
    "src/google/protobuf/io/strtod.cc",
    "src/google/protobuf/io/tokenizer.cc",
    "src/google/protobuf/io/zero_copy_sink.cc",
    "src/google/protobuf/io/zero_copy_stream.cc",
    "src/google/protobuf/io/zero_copy_stream_impl.cc",
    "src/google/protobuf/io/zero_copy_stream_impl_lite.cc",
    "src/google/protobuf/json/internal/lexer.cc",
    "src/google/protobuf/json/internal/message_path.cc",
    "src/google/protobuf/json/internal/parser.cc",
    "src/google/protobuf/json/internal/unparser.cc",
    "src/google/protobuf/json/internal/untyped_message.cc",
    "src/google/protobuf/json/internal/writer.cc",
    "src/google/protobuf/json/internal/zero_copy_buffered_stream.cc",
    "src/google/protobuf/json/json.cc",
    "src/google/protobuf/map.cc",
    "src/google/protobuf/map_field.cc",
    "src/google/protobuf/message.cc",
    "src/google/protobuf/message_lite.cc",
    "src/google/protobuf/micro_string.cc",
    "src/google/protobuf/parse_context.cc",
    "src/google/protobuf/port.cc",
    "src/google/protobuf/raw_ptr.cc",
    "src/google/protobuf/reflection_mode.cc",
    "src/google/protobuf/reflection_ops.cc",
    "src/google/protobuf/repeated_field.cc",
    "src/google/protobuf/repeated_ptr_field.cc",
    "src/google/protobuf/service.cc",
    "src/google/protobuf/stubs/common.cc",
    "src/google/protobuf/text_format.cc",
    "src/google/protobuf/unknown_field_set.cc",
    "src/google/protobuf/util/delimited_message_util.cc",
    "src/google/protobuf/util/field_comparator.cc",
    "src/google/protobuf/util/field_mask_util.cc",
    "src/google/protobuf/util/message_differencer.cc",
    "src/google/protobuf/util/time_util.cc",
    "src/google/protobuf/util/type_resolver_util.cc",
    "src/google/protobuf/wire_format.cc",
    "src/google/protobuf/wire_format_lite.cc",
};

const libprotoc_srcs: []const []const u8 = &.{
    "src/google/protobuf/compiler/code_generator.cc",
    "src/google/protobuf/compiler/code_generator_lite.cc",
    "src/google/protobuf/compiler/command_line_interface.cc",
    "src/google/protobuf/compiler/cpp/enum.cc",
    "src/google/protobuf/compiler/cpp/extension.cc",
    "src/google/protobuf/compiler/cpp/field.cc",
    "src/google/protobuf/compiler/cpp/field_chunk.cc",
    "src/google/protobuf/compiler/cpp/field_generators/cord_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/enum_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/map_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/message_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/primitive_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/string_field.cc",
    "src/google/protobuf/compiler/cpp/field_generators/string_view_field.cc",
    "src/google/protobuf/compiler/cpp/file.cc",
    "src/google/protobuf/compiler/cpp/generator.cc",
    "src/google/protobuf/compiler/cpp/helpers.cc",
    "src/google/protobuf/compiler/cpp/ifndef_guard.cc",
    "src/google/protobuf/compiler/cpp/message.cc",
    "src/google/protobuf/compiler/cpp/message_layout_helper.cc",
    "src/google/protobuf/compiler/cpp/namespace_printer.cc",
    "src/google/protobuf/compiler/cpp/parse_function_generator.cc",
    "src/google/protobuf/compiler/cpp/service.cc",
    "src/google/protobuf/compiler/cpp/tracker.cc",
    "src/google/protobuf/compiler/csharp/csharp_doc_comment.cc",
    "src/google/protobuf/compiler/csharp/csharp_enum.cc",
    "src/google/protobuf/compiler/csharp/csharp_enum_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_field_base.cc",
    "src/google/protobuf/compiler/csharp/csharp_generator.cc",
    "src/google/protobuf/compiler/csharp/csharp_helpers.cc",
    "src/google/protobuf/compiler/csharp/csharp_map_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_message.cc",
    "src/google/protobuf/compiler/csharp/csharp_message_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_primitive_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_reflection_class.cc",
    "src/google/protobuf/compiler/csharp/csharp_repeated_enum_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_repeated_message_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_repeated_primitive_field.cc",
    "src/google/protobuf/compiler/csharp/csharp_source_generator_base.cc",
    "src/google/protobuf/compiler/csharp/csharp_wrapper_field.cc",
    "src/google/protobuf/compiler/csharp/names.cc",
    "src/google/protobuf/compiler/java/context.cc",
    "src/google/protobuf/compiler/java/doc_comment.cc",
    "src/google/protobuf/compiler/java/field_common.cc",
    "src/google/protobuf/compiler/java/file.cc",
    "src/google/protobuf/compiler/java/full/enum.cc",
    "src/google/protobuf/compiler/java/full/enum_field.cc",
    "src/google/protobuf/compiler/java/full/extension.cc",
    "src/google/protobuf/compiler/java/full/generator_factory.cc",
    "src/google/protobuf/compiler/java/full/make_field_gens.cc",
    "src/google/protobuf/compiler/java/full/map_field.cc",
    "src/google/protobuf/compiler/java/full/message.cc",
    "src/google/protobuf/compiler/java/full/message_builder.cc",
    "src/google/protobuf/compiler/java/full/message_field.cc",
    "src/google/protobuf/compiler/java/full/primitive_field.cc",
    "src/google/protobuf/compiler/java/full/service.cc",
    "src/google/protobuf/compiler/java/full/string_field.cc",
    "src/google/protobuf/compiler/java/generator.cc",
    "src/google/protobuf/compiler/java/helpers.cc",
    "src/google/protobuf/compiler/java/internal_helpers.cc",
    "src/google/protobuf/compiler/java/java_features.pb.cc",
    "src/google/protobuf/compiler/java/lite/enum.cc",
    "src/google/protobuf/compiler/java/lite/enum_field.cc",
    "src/google/protobuf/compiler/java/lite/extension.cc",
    "src/google/protobuf/compiler/java/lite/generator_factory.cc",
    "src/google/protobuf/compiler/java/lite/make_field_gens.cc",
    "src/google/protobuf/compiler/java/lite/map_field.cc",
    "src/google/protobuf/compiler/java/lite/message.cc",
    "src/google/protobuf/compiler/java/lite/message_builder.cc",
    "src/google/protobuf/compiler/java/lite/message_field.cc",
    "src/google/protobuf/compiler/java/lite/primitive_field.cc",
    "src/google/protobuf/compiler/java/lite/string_field.cc",
    "src/google/protobuf/compiler/java/message_serialization.cc",
    "src/google/protobuf/compiler/java/name_resolver.cc",
    "src/google/protobuf/compiler/java/names.cc",
    "src/google/protobuf/compiler/java/shared_code_generator.cc",
    "src/google/protobuf/compiler/kotlin/field.cc",
    "src/google/protobuf/compiler/kotlin/file.cc",
    "src/google/protobuf/compiler/kotlin/generator.cc",
    "src/google/protobuf/compiler/kotlin/message.cc",
    "src/google/protobuf/compiler/objectivec/enum.cc",
    "src/google/protobuf/compiler/objectivec/enum_field.cc",
    "src/google/protobuf/compiler/objectivec/extension.cc",
    "src/google/protobuf/compiler/objectivec/field.cc",
    "src/google/protobuf/compiler/objectivec/file.cc",
    "src/google/protobuf/compiler/objectivec/generator.cc",
    "src/google/protobuf/compiler/objectivec/helpers.cc",
    "src/google/protobuf/compiler/objectivec/import_writer.cc",
    "src/google/protobuf/compiler/objectivec/line_consumer.cc",
    "src/google/protobuf/compiler/objectivec/map_field.cc",
    "src/google/protobuf/compiler/objectivec/message.cc",
    "src/google/protobuf/compiler/objectivec/message_field.cc",
    "src/google/protobuf/compiler/objectivec/names.cc",
    "src/google/protobuf/compiler/objectivec/oneof.cc",
    "src/google/protobuf/compiler/objectivec/primitive_field.cc",
    "src/google/protobuf/compiler/objectivec/tf_decode_data.cc",
    "src/google/protobuf/compiler/php/names.cc",
    "src/google/protobuf/compiler/php/php_generator.cc",
    "src/google/protobuf/compiler/plugin.cc",
    "src/google/protobuf/compiler/plugin.pb.cc",
    "src/google/protobuf/compiler/python/generator.cc",
    "src/google/protobuf/compiler/python/helpers.cc",
    "src/google/protobuf/compiler/python/pyi_generator.cc",
    "src/google/protobuf/compiler/retention.cc",
    "src/google/protobuf/compiler/ruby/ruby_generator.cc",
    "src/google/protobuf/compiler/rust/accessors/accessor_case.cc",
    "src/google/protobuf/compiler/rust/accessors/accessors.cc",
    "src/google/protobuf/compiler/rust/accessors/default_value.cc",
    "src/google/protobuf/compiler/rust/accessors/map.cc",
    "src/google/protobuf/compiler/rust/accessors/repeated_field.cc",
    "src/google/protobuf/compiler/rust/accessors/singular_cord.cc",
    "src/google/protobuf/compiler/rust/accessors/singular_message.cc",
    "src/google/protobuf/compiler/rust/accessors/singular_scalar.cc",
    "src/google/protobuf/compiler/rust/accessors/singular_string.cc",
    "src/google/protobuf/compiler/rust/accessors/unsupported_field.cc",
    "src/google/protobuf/compiler/rust/accessors/with_presence.cc",
    "src/google/protobuf/compiler/rust/context.cc",
    "src/google/protobuf/compiler/rust/crate_mapping.cc",
    "src/google/protobuf/compiler/rust/enum.cc",
    "src/google/protobuf/compiler/rust/generator.cc",
    "src/google/protobuf/compiler/rust/message.cc",
    "src/google/protobuf/compiler/rust/naming.cc",
    "src/google/protobuf/compiler/rust/oneof.cc",
    "src/google/protobuf/compiler/rust/relative_path.cc",
    "src/google/protobuf/compiler/rust/rust_field_type.cc",
    "src/google/protobuf/compiler/rust/rust_keywords.cc",
    "src/google/protobuf/compiler/rust/upb_helpers.cc",
    "src/google/protobuf/compiler/subprocess.cc",
    "src/google/protobuf/compiler/versions.cc",
    "src/google/protobuf/compiler/zip_writer.cc",

    "upb_generator/common.cc",
    "upb_generator/common/names.cc",
    "upb_generator/file_layout.cc",
    "upb_generator/minitable/names.cc",
    "upb_generator/minitable/names_internal.cc",
    "upb_generator/plugin.cc",
};

const protoc_srcs: []const []const u8 = &.{
    "src/google/protobuf/compiler/main.cc",
};

const upb_srcs: []const []const u8 = &.{
    "upb/base/status.c",
    "upb/wire/decode.c",
    "upb/wire/encode.c",
    "upb/wire/internal/decoder.c",
    "upb/mem/arena.c",
    "upb/mem/alloc.c",
    "upb/message/copy.c",
    "upb/message/array.c",
    "upb/message/map.c",
    "upb/message/message.c",
    "upb/message/map_sorter.c",
    "upb/message/internal/extension.c",
    "upb/message/internal/message.c",
    "upb/reflection/def_pool.c",
    "upb/reflection/desc_state.c",
    "upb/reflection/message_reserved_range.c",
    "upb/reflection/enum_reserved_range.c",
    "upb/reflection/extension_range.c",
    "upb/reflection/def_type.c",
    "upb/reflection/field_def.c",
    "upb/reflection/file_def.c",
    "upb/reflection/message_def.c",
    "upb/reflection/method_def.c",
    "upb/reflection/service_def.c",
    "upb/reflection/enum_def.c",
    "upb/reflection/enum_value_def.c",
    "upb/reflection/oneof_def.c",
    "upb/reflection/stage0/google/protobuf/descriptor.upb.c",
    "upb/reflection/internal/strdup2.c",
    "upb/reflection/internal/def_builder.c",
    "upb/hash/common.c",
    "upb/mini_descriptor/link.c",
    "upb/mini_descriptor/decode.c",
    "upb/mini_descriptor/build_enum.c",
    "upb/mini_descriptor/internal/base92.c",
    "upb/mini_descriptor/internal/encode.c",
    "upb/mini_table/message.c",
    "upb/mini_table/extension_registry.c",
    "upb/mini_table/internal/message.c",
};
