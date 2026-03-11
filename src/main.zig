// Welcome to ZigXLL :) Add your function modules here.

const nats_conn = @import("nats_conn.zig");

pub const function_modules = .{
    @import("functions.zig"),
};

pub const rtd_servers = .{
    @import("nats_rtd.zig"),
};

/// Called by ZigXLL framework on xlAutoClose. Ensures the shared NATS
/// connection is closed even if no RTD server was active (e.g. only
/// NATS.PUB cells were used).
pub fn deinit() void {
    nats_conn.close();
}
