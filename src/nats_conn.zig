// Shared NATS connection — lazily connects on first use.
// Both the RTD server and NATS.PUB use this to share a single connection.

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const nats = @cImport(@cInclude("nats.h"));
const config = @import("config.zig");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winsock2.h");
});

var mu: std.Io.Mutex = std.Io.Mutex.init;
const mu_io = std.Options.debug_io;
var nc: ?*nats.natsConnection = null;
var nats_opened: bool = false;

/// Get the shared NATS connection, connecting lazily if needed.
/// Returns *anyopaque to avoid cross-cImport opaque type mismatches —
/// callers cast to their own @cImport's natsConnection type.
pub fn getConnection() ?*anyopaque {
    mu.lock(mu_io) catch {};
    defer mu.unlock(mu_io);

    if (nc) |c| return @ptrCast(c);

    // First time — open the nats library
    if (!nats_opened) {
        if (!preflightChecks()) {
            rtd.debugLog("nats_conn: preflight checks FAILED", .{});
            return null;
        }

        const status = nats.nats_Open(-1);
        if (status != nats.NATS_OK) {
            rtd.debugLog("nats_conn: nats_Open failed status={d}", .{status});
            return null;
        }
        nats_opened = true;
    }

    // Load config and connect
    const cfg = config.load();

    var opts: ?*nats.natsOptions = null;
    var cs = nats.natsOptions_Create(&opts);
    if (cs != nats.NATS_OK) {
        rtd.debugLog("nats_conn: natsOptions_Create failed status={d}", .{cs});
        return null;
    }

    const cfg_status = config.applyOptions(@ptrCast(opts.?), &cfg);
    if (cfg_status != nats.NATS_OK) {
        rtd.debugLog("nats_conn: config applyOptions failed status={d}", .{cfg_status});
        nats.natsOptions_Destroy(opts);
        return null;
    }

    const url = cfg.effectiveUrl();
    rtd.debugLog("nats_conn: connecting to '{s}'", .{url});
    cs = nats.natsConnection_Connect(&nc, opts);
    nats.natsOptions_Destroy(opts);

    if (cs != nats.NATS_OK) {
        rtd.debugLog("nats_conn: connect failed status={d}", .{cs});
        return null;
    }

    rtd.debugLog("nats_conn: connected OK, nc={*}", .{nc.?});
    return @ptrCast(nc.?);
}

/// Close and destroy the shared connection. Called by RTD onTerminate.
pub fn close() void {
    mu.lock(mu_io) catch {};
    const c = nc;
    nc = null;
    mu.unlock(mu_io);

    if (c) |conn| {
        rtd.debugLog("nats_conn: closing shared connection", .{});
        nats.natsConnection_Close(conn);
        nats.natsConnection_Destroy(conn);
    }

    if (nats_opened) {
        nats.nats_Close();
        nats_opened = false;
    }
    rtd.debugLog("nats_conn: closed", .{});
}

fn preflightChecks() bool {
    var wsa_data: win.WSADATA = undefined;
    const wsa_rc = win.WSAStartup(win.MAKEWORD(2, 2), &wsa_data);
    if (wsa_rc != 0) {
        rtd.debugLog("nats_conn preflight: WSAStartup FAILED rc={d}", .{wsa_rc});
        return false;
    }
    _ = win.WSACleanup();

    var cs: win.CRITICAL_SECTION = undefined;
    win.InitializeCriticalSection(&cs);
    win.EnterCriticalSection(&cs);
    win.LeaveCriticalSection(&cs);
    win.DeleteCriticalSection(&cs);

    const handle = win.CreateThread(null, 0, &testThreadProc, null, 0, null);
    if (handle == null) {
        rtd.debugLog("nats_conn preflight: CreateThread FAILED err={d}", .{win.GetLastError()});
        return false;
    }
    _ = win.WaitForSingleObject(handle, 5000);
    _ = win.CloseHandle(handle);

    const tls_idx = win.TlsAlloc();
    if (tls_idx == win.TLS_OUT_OF_INDEXES) {
        rtd.debugLog("nats_conn preflight: TlsAlloc FAILED", .{});
        return false;
    }
    _ = win.TlsSetValue(tls_idx, null);
    _ = win.TlsFree(tls_idx);

    const test_ptr = @as(?*anyopaque, std.c.malloc(1024));
    if (test_ptr == null) {
        rtd.debugLog("nats_conn preflight: malloc FAILED", .{});
        return false;
    }
    std.c.free(test_ptr);

    rtd.debugLog("nats_conn preflight: all checks passed", .{});
    return true;
}

fn testThreadProc(_: ?*anyopaque) callconv(.c) u32 {
    return 0;
}
