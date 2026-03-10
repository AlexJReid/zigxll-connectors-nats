const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

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
