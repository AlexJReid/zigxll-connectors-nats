// NATS RTD server — subscribes to NATS subjects and relays published messages to Excel cells.
//
// Usage in Excel: =RTD("zigxll.connectors.nats", , "my.subject")
//   or via wrapper: =NATS("my.subject")
//
// Connects to localhost NATS server (127.0.0.1:4222) on start.
// Subscribes on ConnectData, unsubscribes on DisconnectData.
// Uses vendored nats.c for a production-grade NATS client.

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const nats = @cImport(@cInclude("nats.h"));
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winsock2.h");
});

const allocator = std.heap.c_allocator;

/// Pre-flight checks to ensure the Windows environment is sane before
/// initialising the NATS C library. Logs every step via OutputDebugString
/// so we can see exactly where things go wrong.
fn preflightChecks() bool {
    rtd.debugLog("preflight: starting Win32 environment checks", .{});

    // 1. Winsock — Excel may already have it, but ensure it's available
    rtd.debugLog("preflight: checking WSAStartup", .{});
    var wsa_data: win.WSADATA = undefined;
    const wsa_rc = win.WSAStartup(win.MAKEWORD(2, 2), &wsa_data);
    if (wsa_rc != 0) {
        rtd.debugLog("preflight: WSAStartup FAILED rc={d}", .{wsa_rc});
        return false;
    }
    rtd.debugLog("preflight: WSAStartup OK (version {d}.{d})", .{
        wsa_data.wVersion & 0xFF,
        wsa_data.wVersion >> 8,
    });
    // Clean up — nats.c will call WSAStartup again itself
    _ = win.WSACleanup();

    // 2. Critical sections (mutex primitives used by nats.c)
    rtd.debugLog("preflight: testing CRITICAL_SECTION", .{});
    var cs: win.CRITICAL_SECTION = undefined;
    win.InitializeCriticalSection(&cs);
    win.EnterCriticalSection(&cs);
    win.LeaveCriticalSection(&cs);
    win.DeleteCriticalSection(&cs);
    rtd.debugLog("preflight: CRITICAL_SECTION OK", .{});

    // 3. Thread creation — nats.c uses _beginthreadex which wraps CreateThread
    rtd.debugLog("preflight: testing CreateThread", .{});
    const handle = win.CreateThread(
        null, // default security
        0, // default stack
        &testThreadProc,
        null, // no param
        0, // run immediately
        null, // don't need thread id
    );
    if (handle == null) {
        const err = win.GetLastError();
        rtd.debugLog("preflight: CreateThread FAILED err={d}", .{err});
        return false;
    }
    rtd.debugLog("preflight: CreateThread OK, waiting for thread", .{});
    _ = win.WaitForSingleObject(handle, 5000); // 5s timeout
    _ = win.CloseHandle(handle);
    rtd.debugLog("preflight: test thread completed", .{});

    // 4. TLS slots (nats.c uses TlsAlloc for per-thread error state)
    rtd.debugLog("preflight: testing TLS", .{});
    const tls_idx = win.TlsAlloc();
    if (tls_idx == win.TLS_OUT_OF_INDEXES) {
        rtd.debugLog("preflight: TlsAlloc FAILED", .{});
        return false;
    }
    _ = win.TlsSetValue(tls_idx, null);
    _ = win.TlsFree(tls_idx);
    rtd.debugLog("preflight: TLS OK", .{});

    // 5. Heap — nats.c uses malloc/calloc/free heavily
    rtd.debugLog("preflight: testing C heap (malloc/free)", .{});
    const test_ptr = @as(?*anyopaque, std.c.malloc(1024));
    if (test_ptr == null) {
        rtd.debugLog("preflight: malloc FAILED", .{});
        return false;
    }
    std.c.free(test_ptr);
    rtd.debugLog("preflight: C heap OK", .{});

    rtd.debugLog("preflight: all checks passed", .{});
    return true;
}

fn testThreadProc(_: ?*anyopaque) callconv(.c) u32 {
    rtd.debugLog("preflight: test thread running", .{});
    return 0;
}

const NatsHandler = struct {
    nc: ?*nats.natsConnection = null,
    ctx: ?*rtd.RtdContext = null,

    // topic_id -> subscription handle
    subs: std.AutoHashMap(i32, *nats.natsSubscription) = std.AutoHashMap(i32, *nats.natsSubscription).init(allocator),
    // topic_id -> latest payload (owned, empty slice = no value yet)
    values: std.AutoHashMap(i32, []const u8) = std.AutoHashMap(i32, []const u8).init(allocator),
    // subject -> topic_id (for routing incoming messages)
    subject_map: std.StringHashMap(i32) = std.StringHashMap(i32).init(allocator),
    mu: std.Thread.Mutex = .{},
    // Arena for utf16 conversions — reset once per RefreshData batch
    refresh_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),

    pub fn onStart(self: *NatsHandler, ctx: *rtd.RtdContext) void {
        rtd.debugLog("NATS onStart: entering", .{});
        self.ctx = ctx;

        if (!preflightChecks()) {
            rtd.debugLog("NATS onStart: preflight checks FAILED, aborting", .{});
            return;
        }

        rtd.debugLog("NATS onStart: calling nats_Open(-1)", .{});
        const status = nats.nats_Open(-1);
        if (status != nats.NATS_OK) {
            rtd.debugLog("NATS onStart: nats_Open failed with status={d}", .{status});
            return;
        }
        rtd.debugLog("NATS onStart: nats_Open succeeded", .{});

        rtd.debugLog("NATS onStart: connecting to nats://127.0.0.1:4222", .{});
        const cs = nats.natsConnection_ConnectTo(&self.nc, "nats://127.0.0.1:4222");
        if (cs != nats.NATS_OK) {
            rtd.debugLog("NATS onStart: connect failed with status={d}", .{cs});
            return;
        }

        rtd.debugLog("NATS onStart: connected OK, nc={*}", .{self.nc.?});
    }

    pub fn onConnect(self: *NatsHandler, ctx: *rtd.RtdContext, topic_id: i32, _: usize) void {
        const entry = ctx.topics.get(topic_id) orelse return;
        if (entry.strings.len == 0) return;
        const subject = entry.strings[0];
        const nc = self.nc orelse return;

        const subject_z = allocator.dupeZ(u8, subject) catch return;
        defer allocator.free(subject_z);

        var sub: ?*nats.natsSubscription = null;
        const status = nats.natsConnection_Subscribe(
            &sub,
            nc,
            subject_z.ptr,
            onMsg,
            @ptrCast(self),
        );
        if (status != nats.NATS_OK) {
            rtd.debugLog("NATS subscribe failed for '{s}': status={d}", .{ subject_z, status });
            return;
        }

        self.mu.lock();
        defer self.mu.unlock();

        if (sub) |s| self.subs.put(topic_id, s) catch {};
        self.values.put(topic_id, &.{}) catch {};

        const subj_copy = allocator.dupe(u8, subject) catch return;
        self.subject_map.put(subj_copy, topic_id) catch {
            allocator.free(subj_copy);
        };
    }

    pub fn onDisconnect(self: *NatsHandler, _: *rtd.RtdContext, topic_id: i32, _: usize) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.subs.fetchRemove(topic_id)) |kv| {
            _ = nats.natsSubscription_Unsubscribe(kv.value);
            nats.natsSubscription_Destroy(kv.value);
        }

        if (self.values.fetchRemove(topic_id)) |kv| {
            if (kv.value.len > 0) allocator.free(kv.value);
        }

        // Remove from subject_map
        var to_remove: ?[]const u8 = null;
        var it = self.subject_map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == topic_id) {
                to_remove = e.key_ptr.*;
                break;
            }
        }
        if (to_remove) |key| {
            _ = self.subject_map.remove(key);
            allocator.free(key);
        }
    }

    pub fn onBeforeRefresh(self: *NatsHandler, _: *rtd.RtdContext, _: usize) void {
        _ = self.refresh_arena.reset(.retain_capacity);
    }

    pub fn onRefreshValue(self: *NatsHandler, _: *rtd.RtdContext, topic_id: i32) rtd.RtdValue {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.values.get(topic_id)) |v| {
            if (v.len > 0) {
                const utf16 = std.unicode.utf8ToUtf16LeAlloc(self.refresh_arena.allocator(), v) catch return rtd.RtdValue.na;
                return .{ .string = utf16 };
            }
        }
        // No value received yet - show #N/A until first message arrives
        return rtd.RtdValue.na;
    }

    pub fn onTerminate(self: *NatsHandler, _: *rtd.RtdContext) void {
        rtd.debugLog("NATS onTerminate: entering", .{});

        // Close NATS connection (will stop all subs)
        if (self.nc) |nc| {
            rtd.debugLog("NATS onTerminate: closing connection nc={*}", .{nc});
            nats.natsConnection_Close(nc);
            rtd.debugLog("NATS onTerminate: connection closed", .{});
        }

        self.mu.lock();

        // Destroy subscription handles
        rtd.debugLog("NATS onTerminate: destroying {d} subscriptions", .{self.subs.count()});
        var sit = self.subs.iterator();
        while (sit.next()) |entry| {
            rtd.debugLog("NATS onTerminate: destroying sub for topic_id={d}", .{entry.key_ptr.*});
            nats.natsSubscription_Destroy(entry.value_ptr.*);
        }
        self.subs.deinit();

        // Free stored values
        rtd.debugLog("NATS onTerminate: freeing {d} stored values", .{self.values.count()});
        var vit = self.values.iterator();
        while (vit.next()) |entry| {
            if (entry.value_ptr.*.len > 0) allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();

        // Free subject map keys
        rtd.debugLog("NATS onTerminate: freeing {d} subject_map entries", .{self.subject_map.count()});
        var mit = self.subject_map.iterator();
        while (mit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.subject_map.deinit();
        self.refresh_arena.deinit();

        self.mu.unlock();

        if (self.nc) |nc| {
            rtd.debugLog("NATS onTerminate: destroying connection", .{});
            nats.natsConnection_Destroy(nc);
            self.nc = null;
        }
        rtd.debugLog("NATS onTerminate: calling nats_Close()", .{});
        nats.nats_Close();
        rtd.debugLog("NATS onTerminate: done", .{});
    }

    // nats.c message callback — called from nats.c's internal thread pool
    fn onMsg(
        _: ?*nats.natsConnection,
        _: ?*nats.natsSubscription,
        msg: ?*nats.natsMsg,
        closure: ?*anyopaque,
    ) callconv(.c) void {
        const self: *NatsHandler = @ptrCast(@alignCast(closure orelse return));
        const m = msg orelse return;
        defer nats.natsMsg_Destroy(m);

        const subject_ptr = nats.natsMsg_GetSubject(m) orelse return;
        const data_ptr = nats.natsMsg_GetData(m);
        const raw_data_len = nats.natsMsg_GetDataLength(m);

        if (raw_data_len <= 0) return;
        const data_len: usize = @intCast(raw_data_len);
        if (data_ptr == null) return;

        const subject = std.mem.span(subject_ptr);
        const payload: [*]const u8 = @ptrCast(data_ptr.?);
        const copy = allocator.dupe(u8, payload[0..data_len]) catch return;

        self.mu.lock();
        defer self.mu.unlock();

        const topic_id = self.subject_map.get(subject) orelse {
            allocator.free(copy);
            return;
        };

        // Free old value
        if (self.values.get(topic_id)) |old| {
            if (old.len > 0) allocator.free(old);
        }
        self.values.put(topic_id, copy) catch {
            allocator.free(copy);
            return;
        };

        // Mark dirty and notify Excel
        if (self.ctx) |ctx| {
            if (ctx.topics.getPtr(topic_id)) |entry| {
                entry.dirty = true;
            }
            ctx.notifyExcel();
        }
    }
};

pub const rtd_config: rtd.RtdConfig = .{
    .clsid = rtd.guid("A1B2C3D4-E5F6-7890-ABCD-EF0123456789"),
    .prog_id = "zigxll.connectors.nats",
};

pub const RtdServerType = rtd.RtdServer(NatsHandler, rtd_config);
