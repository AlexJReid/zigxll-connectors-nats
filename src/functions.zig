const std = @import("std");
const xll = @import("xll");
const xl = xll.xl;
const XLValue = xll.XLValue;
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;
const nats = @cImport(@cInclude("nats.h"));
const nats_conn = @import("nats_conn.zig");
const wb = @import("window_buffer.zig");

const allocator = std.heap.c_allocator;

// RTD wrapper — use =NATS.SUB("my.subject") instead of =RTD("zigxll.connectors.nats", , "my.subject")
// Optional second argument controls value interpretation:
//   omitted or "auto" — duck-type: try bool, int, float, fall back to string
//   "string"          — always return as string
//   "number"          — coerce to number (int or float), #VALUE! if not numeric
//   "bool"            — coerce to bool ("true"/"false"), #VALUE! otherwise
//   "$.foo.bar"       — parse payload as JSON, extract field via dot-path, type from JSON
pub const nats_sub = ExcelFunction(.{
    .name = "NATS.SUB",
    .description = "Subscribe to a NATS subject (RTD wrapper)",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "subject", .description = "NATS subject to subscribe to" },
        .{ .name = "type", .description = "Type hint: auto (default), string, number, bool, or $.json.path" },
    },
    .func = natsSubFunc,
});

fn natsSubFunc(subject: []const u8, type_hint: ?[]const u8) !*xll.xl.XLOPER12 {
    if (type_hint) |hint| {
        return xll.rtd_call.subscribe("zigxll.connectors.nats", &.{ subject, hint });
    }
    return xll.rtd_call.subscribe("zigxll.connectors.nats", &.{subject});
}

// Publish a message to a NATS subject.
// =NATS.PUB("subject", value) → publishes value as UTF-8 text; numbers/bools are coerced to string.
pub const nats_pub = ExcelFunction(.{
    .name = "NATS.PUB",
    .description = "Publish a message to a NATS subject",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "subject", .description = "NATS subject to publish to" },
        .{ .name = "payload", .description = "Message payload (string, number, or bool — all sent as UTF-8 text)" },
    },
    .func = natsPubFunc,
});

// Connection info and statistics.
// =NATS.INFO() → returns a 2-column matrix with connection metadata and stats.
pub const nats_info = ExcelFunction(.{
    .name = "NATS.INFO",
    .description = "Show NATS connection info and statistics",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{},
    .func = natsInfoFunc,
});

fn natsInfoFunc() !*xl.XLOPER12 {
    const conn_opaque = nats_conn.getConnection();
    if (conn_opaque == null) {
        const result = try allocator.create(xl.XLOPER12);
        const cell = try toXlCell(strCell("not connected"));
        result.* = .{
            .xltype = xl.xltypeStr | xl.xlbitDLLFree,
            .val = cell.val,
        };
        return result;
    }
    const conn: *nats.natsConnection = @ptrCast(conn_opaque.?);

    // Gather stats
    var stats: ?*nats.natsStatistics = null;
    if (nats.natsStatistics_Create(&stats) != nats.NATS_OK) return error.StatsFailed;
    defer nats.natsStatistics_Destroy(stats);

    if (nats.natsConnection_GetStats(conn, stats) != nats.NATS_OK) return error.StatsFailed;

    var in_msgs: u64 = 0;
    var in_bytes: u64 = 0;
    var out_msgs: u64 = 0;
    var out_bytes: u64 = 0;
    var reconnects: u64 = 0;
    _ = nats.natsStatistics_GetCounts(stats, &in_msgs, &in_bytes, &out_msgs, &out_bytes, &reconnects);

    // Gather connection info
    var url_buf: [256]u8 = undefined;
    var server_id_buf: [256]u8 = undefined;
    _ = nats.natsConnection_GetConnectedUrl(conn, &url_buf, url_buf.len);
    _ = nats.natsConnection_GetConnectedServerId(conn, &server_id_buf, server_id_buf.len);

    const version = std.mem.span(nats.nats_GetVersion());
    const url = std.mem.sliceTo(&url_buf, 0);
    const server_id = std.mem.sliceTo(&server_id_buf, 0);

    // Build rows: [label, value] pairs
    const rows = [_][2]Cell{
        .{ strCell("nats.c"), strCell(version) },
        .{ strCell("url"), strCell(url) },
        .{ strCell("server_id"), strCell(server_id) },
        .{ strCell("in_msgs"), numCell(@floatFromInt(in_msgs)) },
        .{ strCell("in_bytes"), numCell(@floatFromInt(in_bytes)) },
        .{ strCell("out_msgs"), numCell(@floatFromInt(out_msgs)) },
        .{ strCell("out_bytes"), numCell(@floatFromInt(out_bytes)) },
        .{ strCell("reconnects"), numCell(@floatFromInt(reconnects)) },
    };

    const num_rows = rows.len;
    const cells = try allocator.alloc(xl.XLOPER12, num_rows * 2);
    for (0..num_rows) |r| {
        cells[r * 2] = try toXlCell(rows[r][0]);
        cells[r * 2 + 1] = try toXlCell(rows[r][1]);
    }

    const result = try allocator.create(xl.XLOPER12);
    result.* = .{
        .xltype = xl.xltypeMulti | xl.xlbitDLLFree,
        .val = .{ .array = .{
            .lparray = cells.ptr,
            .rows = @intCast(num_rows),
            .columns = 2,
        } },
    };
    return result;
}

const Cell = union(enum) { str: []const u8, num: f64 };

fn strCell(s: []const u8) Cell {
    return .{ .str = s };
}

fn numCell(n: f64) Cell {
    return .{ .num = n };
}

fn toXlCell(cell: Cell) !xl.XLOPER12 {
    switch (cell) {
        .num => |n| return .{ .xltype = xl.xltypeNum, .val = .{ .num = n } },
        .str => |s| {
            const utf16_len = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8;
            const buf = try allocator.alloc(u16, utf16_len + 2);
            buf[0] = @intCast(utf16_len);
            _ = std.unicode.utf8ToUtf16Le(buf[1 .. utf16_len + 1], s) catch return error.InvalidUtf8;
            buf[utf16_len + 1] = 0;
            return .{ .xltype = xl.xltypeStr, .val = .{ .str = @ptrCast(buf.ptr) } };
        },
    }
}

// Subscribe to a NATS subject in window mode — accumulates the last N f64 values.
// Returns a handle string "subject#generation" that changes on each new value.
// Use NATS.SUBWIN_VALS(handle) to read the accumulated values as a spill array.
pub const nats_subwin = ExcelFunction(.{
    .name = "NATS.SUBWIN",
    .description = "Subscribe to a NATS subject and accumulate last N numeric values",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "subject", .description = "NATS subject to subscribe to" },
        .{ .name = "n", .description = "Window size (max values to keep)" },
    },
    .func = natsSubwinFunc,
});

fn natsSubwinFunc(subject: []const u8, n: f64) !*xl.XLOPER12 {
    const cap = @as(u32, @intFromFloat(@max(1, @min(n, @as(f64, wb.max_window_size)))));
    const win_tag = std.fmt.allocPrint(allocator, "win:{d}", .{cap}) catch return XLValue.na();
    defer allocator.free(win_tag);
    return xll.rtd_call.subscribe("zigxll.connectors.nats", &.{ subject, win_tag });
}

// Read accumulated window values as a vertical spill array.
// Takes the handle string returned by NATS.SUBWIN.
pub const nats_subwin_vals = ExcelFunction(.{
    .name = "NATS.SUBWIN.VALS",
    .description = "Read accumulated window values as a spill array",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "handle", .description = "Handle from NATS.SUBWIN" },
    },
    .func = natsSubwinValsFunc,
});

fn natsSubwinValsFunc(handle: []const u8) ![][]const f64 {
    // Parse "subject#generation" — we only need the subject part
    const sep = std.mem.indexOfScalar(u8, handle, '#') orelse return error.InvalidHandle;
    const subject = handle[0..sep];

    const values = (try wb.snapshotOf(subject)) orelse return error.BufferNotFound;
    defer allocator.free(values);

    if (values.len == 0) {
        // Can't return empty spill — defer above handles the free
        return error.EmptyBuffer;
    }

    // Build Nx1 column matrix
    const rows = try allocator.alloc([]const f64, values.len);
    for (values, 0..) |v, i| {
        const row = try allocator.alloc(f64, 1);
        row[0] = v;
        rows[i] = row;
    }
    return rows;
}

fn natsPubFunc(subject: []const u8, payload: xll.XLValue) ![]const u8 {
    const conn: *nats.natsConnection = @ptrCast(nats_conn.getConnection() orelse return error.NotConnected);

    const payload_str = blk: {
        if (payload.is_str()) {
            break :blk try payload.as_utf8str();
        } else if (payload.is_num()) {
            const n = try payload.as_double();
            // Whole numbers that fit in i64: no decimal point.
            if (n == @trunc(n) and @abs(n) < 1e15) {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))});
            }
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{n});
        } else if (payload.is_bool()) {
            break :blk try allocator.dupe(u8, if (try payload.as_bool()) "true" else "false");
        } else {
            return error.UnsupportedPayloadType;
        }
    };
    defer allocator.free(payload_str);

    const subject_z = try allocator.dupeZ(u8, subject);
    defer allocator.free(subject_z);

    const status = nats.natsConnection_Publish(conn, subject_z.ptr, payload_str.ptr, @intCast(payload_str.len));
    if (status != nats.NATS_OK) return error.PublishFailed;

    const prefix = "PUB: ";
    const result = try allocator.alloc(u8, prefix.len + subject.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], subject);
    return result;
}
