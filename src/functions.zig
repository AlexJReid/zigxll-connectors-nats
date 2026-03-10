const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

const allocator = std.heap.c_allocator;

// Example custom function
pub const double = ExcelFunction(.{
    .name = "dblit",
    .description = "Double a number",
    .category = "Zig Functions",
    .params = &[_]ParamMeta{
        .{ .name = "x", .description = "Number to double" },
    },
    .func = doubleFunc,
});

fn doubleFunc(x: f64) !f64 {
    return x * 2;
}

// RTD wrapper — use =TIMER() instead of =RTD("zigxll.connectors.timer", , "tick")
pub const timer = ExcelFunction(.{
    .name = "TIMER",
    .description = "Live ticking counter (RTD wrapper)",
    .category = "Zig Functions",
    .thread_safe = false,
    .params = &[_]ParamMeta{},
    .func = timerFunc,
});

fn timerFunc() !*xll.xl.XLOPER12 {
    return xll.rtd_call.subscribe("zigxll.connectors.timer", &.{"tick"});
}

// NATS RTD wrapper — use =NATS.SUB("my.subject") instead of =RTD("zigxll.connectors.nats", , "my.subject")
pub const nats_sub = ExcelFunction(.{
    .name = "NATS.SUB",
    .description = "Subscribe to a NATS subject (RTD wrapper)",
    .category = "NATS",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "subject", .description = "NATS subject to subscribe to" },
    },
    .func = natsSubFunc,
});

fn natsSubFunc(subject: []const u8) !*xll.xl.XLOPER12 {
    return xll.rtd_call.subscribe("zigxll.connectors.nats", &.{subject});
}
