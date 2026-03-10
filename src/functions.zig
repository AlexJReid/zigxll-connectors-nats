const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

const allocator = std.heap.c_allocator;

// RTD wrapper — use =NATS.SUB("my.subject") instead of =RTD("zigxll.connectors.nats", , "my.subject")
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
