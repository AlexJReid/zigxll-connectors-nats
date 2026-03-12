// NATS RTD server — subscribes to NATS subjects and relays published messages to Excel cells.
//
// Usage in Excel: =RTD("zigxll.connectors.nats", , "my.subject")
//   or via wrapper: =NATS.SUB("my.subject")
//
// Window mode: =NATS.SUBWIN("my.subject", 50) subscribes and accumulates
// the last N f64 values in a ring buffer, returning a handle string that
// changes on each new value. Use NATS.SUBWIN_VALS(handle) to read the buffer.

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const nats = @cImport(@cInclude("nats.h"));
const vi = @import("value_interp.zig");
const nats_conn = @import("nats_conn.zig");
const wb = @import("window_buffer.zig");

const allocator = std.heap.c_allocator;

const TypeHint = vi.TypeHint;

const NatsHandler = struct {
    nc: ?*nats.natsConnection = null,
    ctx: ?*rtd.RtdContext = null,

    // topic_id -> subscription handle
    subs: std.AutoHashMap(i32, *nats.natsSubscription) = std.AutoHashMap(i32, *nats.natsSubscription).init(allocator),
    // topic_id -> latest payload (owned, empty slice = no value yet)
    values: std.AutoHashMap(i32, []const u8) = std.AutoHashMap(i32, []const u8).init(allocator),
    // topic_id -> type hint for value interpretation
    type_hints: std.AutoHashMap(i32, TypeHint) = std.AutoHashMap(i32, TypeHint).init(allocator),
    // subject -> topic_id (for routing incoming messages)
    subject_map: std.StringHashMap(i32) = std.StringHashMap(i32).init(allocator),
    // topic_ids that are in window mode (value = subject for handle formatting)
    window_topics: std.AutoHashMap(i32, []const u8) = std.AutoHashMap(i32, []const u8).init(allocator),
    mu: std.Thread.Mutex = .{},
    // Arena for utf16 conversions — reset once per RefreshData batch
    refresh_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),

    pub fn onStart(self: *NatsHandler, ctx: *rtd.RtdContext) void {
        rtd.debugLog("NATS onStart: entering", .{});
        self.ctx = ctx;
        self.nc = @ptrCast(nats_conn.getConnection());
        if (self.nc) |nc| {
            rtd.debugLog("NATS onStart: connected OK, nc={*}", .{nc});
        } else {
            rtd.debugLog("NATS onStart: connection failed", .{});
        }
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

        // Check for window mode: second topic string starting with "win:"
        const win_cap = parseWindowCapacity(entry.strings);
        if (win_cap) |cap| {
            _ = wb.getOrCreate(subject, cap) catch {};
            const subj_ref = allocator.dupe(u8, subject) catch return;
            self.window_topics.put(topic_id, subj_ref) catch {
                allocator.free(subj_ref);
            };
        } else {
            // Parse type hint from second topic string (if present)
            const hint = vi.parseTypeHint(entry.strings);
            self.type_hints.put(topic_id, hint) catch {};
        }

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
        _ = self.type_hints.remove(topic_id);

        // Clean up window buffer if this was a window topic
        if (self.window_topics.fetchRemove(topic_id)) |kv| {
            wb.remove(kv.value);
            allocator.free(kv.value);
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

        // Window mode: return handle string "subject#generation"
        if (self.window_topics.get(topic_id)) |subject| {
            const gen = wb.generation(subject);
            const handle = std.fmt.allocPrint(self.refresh_arena.allocator(), "{s}#{d}", .{ subject, gen }) catch return rtd.RtdValue.na;
            const utf16_len = std.unicode.calcUtf16LeLen(handle) catch return rtd.RtdValue.na;
            const utf16 = self.refresh_arena.allocator().alloc(u16, utf16_len) catch return rtd.RtdValue.na;
            _ = std.unicode.utf8ToUtf16Le(utf16, handle) catch return rtd.RtdValue.na;
            return .{ .string = utf16 };
        }

        const v = self.values.get(topic_id) orelse return rtd.RtdValue.na;
        if (v.len == 0) return rtd.RtdValue.na;

        const hint = self.type_hints.get(topic_id) orelse TypeHint{};
        return toRtdValue(vi.interpretValue(v, hint, self.refresh_arena.allocator()));
    }

    pub fn onTerminate(self: *NatsHandler, _: *rtd.RtdContext) void {
        rtd.debugLog("NATS onTerminate: entering", .{});

        self.mu.lock();

        // Destroy subscription handles
        rtd.debugLog("NATS onTerminate: destroying {d} subscriptions", .{self.subs.count()});
        var sit = self.subs.iterator();
        while (sit.next()) |entry| {
            rtd.debugLog("NATS onTerminate: destroying sub for topic_id={d}", .{entry.key_ptr.*});
            _ = nats.natsSubscription_Unsubscribe(entry.value_ptr.*);
            nats.natsSubscription_Destroy(entry.value_ptr.*);
        }
        self.subs.deinit();

        self.type_hints.deinit();

        // Free window topic subject copies
        {
            var wit = self.window_topics.iterator();
            while (wit.next()) |entry| {
                allocator.free(entry.value_ptr.*);
            }
            self.window_topics.deinit();
        }

        // Destroy all window buffers
        wb.deinitAll();

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

        self.nc = null;
        self.mu.unlock();

        // Close the shared connection
        nats_conn.close();
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

        // Window mode: parse f64 and push to ring buffer
        if (self.window_topics.contains(topic_id)) {
            const trimmed = std.mem.trim(u8, copy, &[_]u8{ ' ', '\t', '\n', '\r' });
            if (std.fmt.parseFloat(f64, trimmed)) |value| {
                // Push outside our lock — window_buffer has its own mutex
                // But we're already holding self.mu here, and pushValue takes wb.mu.
                // This is fine: lock order is always self.mu -> wb.mu.
                _ = wb.pushValue(subject, value);
            } else |_| {
                // Non-numeric message in window mode — skip
            }
            allocator.free(copy);
        } else {
            // Normal mode: store latest payload
            if (self.values.get(topic_id)) |old| {
                if (old.len > 0) allocator.free(old);
            }
            self.values.put(topic_id, copy) catch {
                allocator.free(copy);
                return;
            };
        }

        // Mark dirty and notify Excel
        if (self.ctx) |ctx| {
            if (ctx.topics.getPtr(topic_id)) |entry| {
                entry.dirty = true;
            }
            ctx.notifyExcel();
        }
    }
};

/// Map platform-neutral vi.Value to the xll rtd.RtdValue union.
fn toRtdValue(v: vi.Value) rtd.RtdValue {
    return switch (v) {
        .int => |i| .{ .int = i },
        .double => |f| .{ .double = f },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .boolean = b },
        .err => |code| .{ .err = @bitCast(code) },
        .empty => .empty,
        .na => rtd.RtdValue.na,
    };
}

/// Parse "win:<n>" from the second topic string. Returns capacity or null.
fn parseWindowCapacity(strings: []const []const u8) ?u32 {
    if (strings.len < 2) return null;
    const s = strings[1];
    if (s.len > 4 and std.mem.startsWith(u8, s, "win:")) {
        return std.fmt.parseInt(u32, s[4..], 10) catch null;
    }
    return null;
}

pub const rtd_config: rtd.RtdConfig = .{
    .clsid = rtd.guid("F3910D1B-338F-49D4-A364-B113EA6CE115"),
    .prog_id = "zigxll.connectors.nats",
};

pub const RtdServerType = rtd.RtdServer(NatsHandler, rtd_config);
