// Welcome to ZigXLL :) Add your function modules here.

pub const function_modules = .{
    @import("functions.zig"),
};

pub const rtd_servers = .{
    @import("timer_rtd.zig"),
    @import("nats_rtd.zig"),
};
