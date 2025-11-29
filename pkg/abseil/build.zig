const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("abseil-cpp", .{});

    const abseil = b.addLibrary(.{
        .name = "abseil",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });

    if (target.result.os.tag == .windows) {
        abseil.linkSystemLibrary("dbghelp");
    }

    abseil.addIncludePath(upstream.path(""));
    abseil.addCSourceFiles(.{
        .root = upstream.path("absl"),
        .files = asbeil_sources,
        .language = .cpp,
    });
    abseil.installHeadersDirectory(
        upstream.path("absl"),
        "absl",
        .{ .include_extensions = &.{ ".h", ".inc" } },
    );

    b.installArtifact(abseil);
}

const asbeil_sources: []const []const u8 = &.{
    "base/log_severity.cc",
    "base/internal/cycleclock.cc",
    "base/internal/spinlock.cc",
    "base/internal/spinlock_wait.cc",
    "base/internal/sysinfo.cc",
    "base/internal/thread_identity.cc",
    "base/internal/unscaledcycleclock.cc",
    "base/internal/raw_logging.cc",
    "base/internal/low_level_alloc.cc",
    "base/internal/throw_delegate.cc",
    "base/internal/strerror.cc",

    "strings/cord.cc",
    "strings/cord_analysis.cc",
    "strings/internal/cord_internal.cc",
    "strings/internal/cord_rep_btree.cc",
    "strings/internal/cord_rep_btree_navigator.cc",
    "strings/internal/cord_rep_btree_reader.cc",
    "strings/internal/cord_rep_crc.cc",
    "strings/internal/cord_rep_consume.cc",
    "strings/internal/cordz_functions.cc",
    "strings/internal/cordz_handle.cc",
    "strings/internal/cordz_info.cc",
    "strings/internal/cordz_sample_token.cc",
    "strings/internal/str_format/arg.cc",
    "strings/internal/str_format/bind.cc",
    "strings/internal/str_format/extension.cc",
    "strings/internal/str_format/float_conversion.cc",
    "strings/internal/str_format/output.cc",
    "strings/internal/str_format/parser.cc",
    "strings/internal/charconv_bigint.cc",
    "strings/internal/charconv_parse.cc",
    "strings/internal/damerau_levenshtein_distance.cc",
    "strings/internal/memutil.cc",
    "strings/internal/stringify_sink.cc",
    "strings/internal/utf8.cc",
    "strings/internal/escaping.cc",

    "debugging/symbolize.cc",
    "debugging/stacktrace.cc",
    "debugging/leak_check.cc",
    "debugging/internal/examine_stack.cc",
    "debugging/internal/address_is_readable.cc",
    "debugging/internal/demangle.cc",
    "debugging/internal/vdso_support.cc",
    "debugging/internal/elf_mem_image.cc",
    "debugging/internal/demangle_rust.cc",
    "debugging/internal/decode_rust_punycode.cc",
    "debugging/internal/utf8_for_code_point.cc",

    "hash/internal/hash.cc",

    "log/die_if_null.cc",
    "log/initialize.cc",
    "log/log_sink.cc",
    "log/globals.cc",
    "log/internal/log_message.cc",
    "log/internal/structured_proto.cc",
    "log/internal/check_op.cc",
    "log/internal/log_sink_set.cc",
    "log/internal/proto.cc",
    "log/internal/globals.cc",
    "log/internal/log_format.cc",
    "log/internal/nullguard.cc",
    "log/internal/conditions.cc",

    "random/discrete_distribution.cc",
    "random/gaussian_distribution.cc",

    "status/status.cc",
    "status/status_payload_printer.cc",
    "status/statusor.cc",
    "strings/ascii.cc",
    "strings/charconv.cc",
    "strings/escaping.cc",
    "strings/match.cc",
    "strings/numbers.cc",
    "strings/str_cat.cc",
    "strings/str_replace.cc",
    "strings/str_split.cc",
    "strings/substitute.cc",
    "status/internal/status_internal.cc",

    // absl::synchronization
    "synchronization/barrier.cc",
    "synchronization/blocking_counter.cc",
    "synchronization/notification.cc",
    "synchronization/mutex.cc",
    "synchronization/internal/create_thread_identity.cc",
    "synchronization/internal/futex_waiter.cc",
    "synchronization/internal/per_thread_sem.cc",
    "synchronization/internal/pthread_waiter.cc",
    "synchronization/internal/sem_waiter.cc",
    "synchronization/internal/stdcpp_waiter.cc",
    "synchronization/internal/waiter_base.cc",
    "synchronization/internal/win32_waiter.cc",
    "synchronization/internal/graphcycles.cc",
    "synchronization/internal/kernel_timeout.cc",

    "time/civil_time.cc",
    "time/clock.cc",
    "time/duration.cc",
    "time/format.cc",
    "time/time.cc",
    //"time/internal/get_current_time_chrono.inc",
    "time/internal/get_current_time_posix.inc",
    "time/internal/cctz/src/civil_time_detail.cc",
    "time/internal/cctz/src/time_zone_fixed.cc",
    "time/internal/cctz/src/time_zone_format.cc",
    "time/internal/cctz/src/time_zone_if.cc",
    "time/internal/cctz/src/time_zone_impl.cc",
    "time/internal/cctz/src/time_zone_info.cc",
    "time/internal/cctz/src/time_zone_libc.cc",
    "time/internal/cctz/src/time_zone_lookup.cc",
    "time/internal/cctz/src/time_zone_posix.cc",
    "time/internal/cctz/src/zone_info_source.cc",

    "container/internal/raw_hash_set.cc",
    "container/internal/hashtablez_sampler.cc",
    "container/internal/hashtablez_sampler_force_weak_definition.cc",

    "crc/crc32c.cc",
    "crc/internal/crc.cc",
    "crc/internal/cpu_detect.cc",
    "crc/internal/crc_cord_state.cc",
    "crc/internal/crc_x86_arm_combined.cc",
    "crc/internal/crc_memcpy_fallback.cc",
    "crc/internal/crc_memcpy_x86_arm_combined.cc",
    "crc/internal/crc_non_temporal_memcpy.cc",

    "profiling/internal/exponential_biased.cc",

    "numeric/int128.cc",
};
