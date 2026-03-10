const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .msvc,
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // Create a module for our user functions (don't add imports yet)
    const user_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the XLL using the framework's helper
    const xll_build = @import("xll");
    const xll = xll_build.buildXll(b, .{
        .name = "zigxll-connectors-nats",
        .user_module = user_module,
        .target = target,
        .optimize = optimize,
    });

    // Vendor nats.c — compile as a static C library, no TLS, no streaming
    const nats_src = b.path("vendor/nats.c/src");

    const nats_core_sources: []const []const u8 = &.{
        "asynccb.c",        "buf.c",         "comsock.c",          "conn.c",
        "crypto.c",         "dispatch.c",    "hash.c",             "js.c",
        "jsm.c",            "kv.c",          "micro.c",            "micro_client.c",
        "micro_endpoint.c", "micro_error.c", "micro_monitoring.c", "micro_request.c",
        "msg.c",            "nats.c",        "natstime.c",         "nkeys.c",
        "nuid.c",           "object.c",      "opts.c",             "parser.c",
        "pub.c",            "srvpool.c",     "stats.c",            "status.c",
        "sub.c",            "timer.c",       "url.c",              "util.c",
    };

    const nats_glib_sources: []const []const u8 = &.{
        "glib/glib.c",               "glib/glib_async_cb.c",
        "glib/glib_dispatch_pool.c", "glib/glib_gc.c",
        "glib/glib_last_error.c",    "glib/glib_ssl.c",
        "glib/glib_timer.c",
    };

    const nats_win_sources: []const []const u8 = &.{
        "win/cond.c", "win/mutex.c", "win/sock.c", "win/strings.c", "win/thread.c",
    };

    const nats_c_flags: []const []const u8 = &.{
        "-D_REENTRANT",
        "-DNATS_STATIC",
    };

    xll.addCSourceFiles(.{
        .root = nats_src,
        .files = nats_core_sources,
        .flags = nats_c_flags,
    });
    xll.addCSourceFiles(.{
        .root = nats_src,
        .files = nats_glib_sources,
        .flags = nats_c_flags,
    });
    xll.addCSourceFiles(.{
        .root = nats_src,
        .files = nats_win_sources,
        .flags = nats_c_flags,
    });
    // MSVC CRT stubs (safe in XLL context — Excel already initialized the CRT)
    xll.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"msvc_stubs.c"},
    });

    // Include paths for nats.c internal headers
    xll.addIncludePath(nats_src);
    xll.addIncludePath(b.path("vendor/nats.c/src/include"));
    xll.addIncludePath(b.path("vendor/nats.c/src/win"));
    xll.addIncludePath(b.path("vendor/nats.c/src/glib"));

    // Windows system libs needed by nats.c
    user_module.linkSystemLibrary("ws2_32", .{});


    // Also add include path to user module so Zig code can @cImport nats.h
    user_module.addIncludePath(nats_src);
    user_module.addIncludePath(b.path("vendor/nats.c/src/include"));
    user_module.addIncludePath(b.path("vendor/nats.c/src/win"));

    // Install the XLL (rename .dll to .xll)
    const install_xll = b.addInstallFile(xll.getEmittedBin(), "lib/zigxll-connectors-nats.xll");
    b.getInstallStep().dependOn(&install_xll.step);
}
