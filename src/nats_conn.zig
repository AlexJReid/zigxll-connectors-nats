// Shared NATS connection, backed by the official nats-io/nats.zig client.

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const nats = @import("nats");
const config = @import("config.zig");

const allocator = std.heap.c_allocator;
const mu_io = std.Options.debug_io;

var mu: std.Io.Mutex = std.Io.Mutex.init;
var nc: ?*nats.Client = null;
var io_backend: ?*std.Io.Threaded = null;
var connected_url: ?[]const u8 = null;

pub fn getConnection() ?*nats.Client {
    mu.lock(mu_io) catch {};
    defer mu.unlock(mu_io);

    if (nc) |c| return c;

    const cfg = config.load();
    const options = config.connectionOptions(&cfg);
    const url = config.connectionUrl(&cfg) catch |err| {
        rtd.debugLog("nats_conn: config URL failed: {s}", .{@errorName(err)});
        return null;
    };
    errdefer allocator.free(url);

    const backend = allocator.create(std.Io.Threaded) catch return null;
    errdefer allocator.destroy(backend);
    backend.* = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    errdefer backend.deinit();

    const conn = nats.Client.connect(allocator, backend.io(), url, options) catch |err| {
        rtd.debugLog("nats_conn: connect to '{s}' failed: {s}", .{ url, @errorName(err) });
        return null;
    };

    io_backend = backend;
    connected_url = url;
    nc = conn;
    rtd.debugLog("nats_conn: connected OK to '{s}'", .{url});
    return conn;
}

pub fn close() void {
    mu.lock(mu_io) catch {};
    const c = nc;
    const backend = io_backend;
    const url = connected_url;
    nc = null;
    io_backend = null;
    connected_url = null;
    mu.unlock(mu_io);

    if (c) |conn| {
        rtd.debugLog("nats_conn: closing shared connection", .{});
        conn.deinit();
    }
    if (backend) |b| {
        b.deinit();
        allocator.destroy(b);
    }
    if (url) |u| allocator.free(u);
    rtd.debugLog("nats_conn: closed", .{});
}

pub fn currentUrl() []const u8 {
    return connected_url orelse "";
}
