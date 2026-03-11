/// Pure value interpretation logic — no xll/nats/COM dependencies.
///
/// Extracted so it can be tested natively on any platform without
/// cross-compiling for Windows or linking the XLL framework.
const std = @import("std");

pub const ValueMode = enum {
    auto, // duck-type: try bool, int, float, fall back to string
    string, // always string
    number, // coerce to number
    boolean, // coerce to bool
    json_path, // parse JSON + extract dot-path, type from JSON value
};

pub const TypeHint = struct {
    mode: ValueMode = .auto,
    path: []const u8 = "", // dot-path for json_path mode (e.g. "price.last")
};

/// Platform-neutral value representation. The RTD layer maps this to
/// `rtd.RtdValue` before handing it back to Excel.
pub const Value = union(enum) {
    int: i32,
    double: f64,
    string: []const u16, // UTF-16LE, arena-allocated
    boolean: bool,
    err: u32, // SCODE error code
    empty,
    na,
};

/// #VALUE! SCODE
pub const value_err_code: u32 = 0x800A07D0;

/// #N/A SCODE
pub const na_err_code: u32 = 0x80020004;

pub fn parseTypeHint(strings: []const []const u8) TypeHint {
    if (strings.len < 2) return .{};
    const hint = strings[1];
    if (hint.len == 0) return .{};

    if (std.mem.eql(u8, hint, "string")) return .{ .mode = .string };
    if (std.mem.eql(u8, hint, "number")) return .{ .mode = .number };
    if (std.mem.eql(u8, hint, "bool")) return .{ .mode = .boolean };
    if (std.mem.eql(u8, hint, "auto")) return .{ .mode = .auto };

    // JSONPath: must start with "$."
    if (hint.len > 2 and hint[0] == '$' and hint[1] == '.') {
        return .{ .mode = .json_path, .path = hint[2..] };
    }

    return .{};
}

pub fn interpretValue(v: []const u8, hint: TypeHint, arena: std.mem.Allocator) Value {
    return switch (hint.mode) {
        .string => toStringValue(v, arena),
        .number => toNumberValue(v) orelse .{ .err = value_err_code },
        .boolean => toBoolValue(v) orelse .{ .err = value_err_code },
        .json_path => jsonPathValue(v, hint.path, arena),
        .auto => autoValue(v, arena),
    };
}

pub fn autoValue(v: []const u8, arena: std.mem.Allocator) Value {
    // Try bool
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };

    // Try integer
    if (std.fmt.parseInt(i32, v, 10)) |i| return .{ .int = i } else |_| {}

    // Try float
    if (std.fmt.parseFloat(f64, v)) |f| return .{ .double = f } else |_| {}

    // Fall back to string
    return toStringValue(v, arena);
}

pub fn toStringValue(v: []const u8, arena: std.mem.Allocator) Value {
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(arena, v) catch return .na;
    return .{ .string = utf16 };
}

pub fn toNumberValue(v: []const u8) ?Value {
    if (std.fmt.parseInt(i32, v, 10)) |i| return .{ .int = i } else |_| {}
    if (std.fmt.parseFloat(f64, v)) |f| return .{ .double = f } else |_| {}
    return null;
}

pub fn toBoolValue(v: []const u8) ?Value {
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };
    return null;
}

pub fn jsonPathValue(v: []const u8, path: []const u8, arena: std.mem.Allocator) Value {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, v, .{}) catch return .{ .err = value_err_code };
    const json_val = walkJsonPath(parsed.value, path) orelse return .{ .err = value_err_code };
    return jsonToValue(json_val, arena);
}

/// Walk a dot-separated path like "price.last" through a JSON object tree.
pub fn walkJsonPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var current = root;
    var remaining = path;

    while (remaining.len > 0) {
        const obj = switch (current) {
            .object => |o| o,
            else => return null,
        };

        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse {
            // Last segment
            return obj.get(remaining);
        };

        current = obj.get(remaining[0..dot]) orelse return null;
        remaining = remaining[dot + 1 ..];
    }

    return current;
}

pub fn jsonToValue(val: std.json.Value, arena: std.mem.Allocator) Value {
    return switch (val) {
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = @as(i32, @truncate(i)) },
        .float => |f| .{ .double = f },
        .number_string => |s| toNumberValue(s) orelse toStringValue(s, arena),
        .string => |s| toStringValue(s, arena),
        .null => .empty,
        else => .{ .err = value_err_code },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// --- parseTypeHint ---------------------------------------------------------

test "parseTypeHint: no second string defaults to auto" {
    const h = parseTypeHint(&.{"subject"});
    try testing.expectEqual(ValueMode.auto, h.mode);
}

test "parseTypeHint: empty hint defaults to auto" {
    const h = parseTypeHint(&.{ "subject", "" });
    try testing.expectEqual(ValueMode.auto, h.mode);
}

test "parseTypeHint: known keywords" {
    try testing.expectEqual(ValueMode.string, parseTypeHint(&.{ "s", "string" }).mode);
    try testing.expectEqual(ValueMode.number, parseTypeHint(&.{ "s", "number" }).mode);
    try testing.expectEqual(ValueMode.boolean, parseTypeHint(&.{ "s", "bool" }).mode);
    try testing.expectEqual(ValueMode.auto, parseTypeHint(&.{ "s", "auto" }).mode);
}

test "parseTypeHint: json path" {
    const h = parseTypeHint(&.{ "s", "$.price.last" });
    try testing.expectEqual(ValueMode.json_path, h.mode);
    try testing.expectEqualStrings("price.last", h.path);
}

test "parseTypeHint: unknown hint falls back to auto" {
    const h = parseTypeHint(&.{ "s", "nonsense" });
    try testing.expectEqual(ValueMode.auto, h.mode);
}

test "parseTypeHint: dollar without dot falls back to auto" {
    const h = parseTypeHint(&.{ "s", "$x" });
    try testing.expectEqual(ValueMode.auto, h.mode);
}

// --- autoValue -------------------------------------------------------------

test "autoValue: booleans" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectEqual(Value{ .boolean = true }, autoValue("true", arena.allocator()));
    try testing.expectEqual(Value{ .boolean = false }, autoValue("false", arena.allocator()));
}

test "autoValue: integers" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectEqual(Value{ .int = 42 }, autoValue("42", arena.allocator()));
    try testing.expectEqual(Value{ .int = -1 }, autoValue("-1", arena.allocator()));
    try testing.expectEqual(Value{ .int = 0 }, autoValue("0", arena.allocator()));
}

test "autoValue: floats" {
    var arena = testArena();
    defer arena.deinit();
    const v = autoValue("3.14", arena.allocator());
    try testing.expectEqual(@as(f64, 3.14), v.double);
}

test "autoValue: string fallback" {
    var arena = testArena();
    defer arena.deinit();
    const v = autoValue("hello", arena.allocator());
    try testing.expect(v == .string);
    // "hello" in UTF-16LE
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("hello");
    try testing.expectEqualSlices(u16, expected, v.string);
}

// --- toNumberValue ---------------------------------------------------------

test "toNumberValue: valid int" {
    try testing.expectEqual(Value{ .int = 99 }, toNumberValue("99").?);
}

test "toNumberValue: valid float" {
    const v = toNumberValue("1.5").?;
    try testing.expectEqual(@as(f64, 1.5), v.double);
}

test "toNumberValue: not a number" {
    try testing.expect(toNumberValue("abc") == null);
}

// --- toBoolValue -----------------------------------------------------------

test "toBoolValue: valid" {
    try testing.expectEqual(Value{ .boolean = true }, toBoolValue("true").?);
    try testing.expectEqual(Value{ .boolean = false }, toBoolValue("false").?);
}

test "toBoolValue: case sensitive" {
    try testing.expect(toBoolValue("True") == null);
    try testing.expect(toBoolValue("FALSE") == null);
}

test "toBoolValue: garbage" {
    try testing.expect(toBoolValue("yes") == null);
}

// --- interpretValue --------------------------------------------------------

test "interpretValue: string mode" {
    var arena = testArena();
    defer arena.deinit();
    const v = interpretValue("42", .{ .mode = .string }, arena.allocator());
    try testing.expect(v == .string);
}

test "interpretValue: number mode with non-numeric" {
    var arena = testArena();
    defer arena.deinit();
    const v = interpretValue("abc", .{ .mode = .number }, arena.allocator());
    try testing.expectEqual(Value{ .err = value_err_code }, v);
}

test "interpretValue: bool mode with non-bool" {
    var arena = testArena();
    defer arena.deinit();
    const v = interpretValue("42", .{ .mode = .boolean }, arena.allocator());
    try testing.expectEqual(Value{ .err = value_err_code }, v);
}

// --- jsonPathValue ---------------------------------------------------------

test "jsonPathValue: simple field" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"price\":42}", "price", arena.allocator());
    try testing.expectEqual(Value{ .int = 42 }, v);
}

test "jsonPathValue: nested path" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"a\":{\"b\":true}}", "a.b", arena.allocator());
    try testing.expectEqual(Value{ .boolean = true }, v);
}

test "jsonPathValue: missing key" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"a\":1}", "b", arena.allocator());
    try testing.expectEqual(Value{ .err = value_err_code }, v);
}

test "jsonPathValue: invalid JSON" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("not json", "x", arena.allocator());
    try testing.expectEqual(Value{ .err = value_err_code }, v);
}

test "jsonPathValue: null value" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"x\":null}", "x", arena.allocator());
    try testing.expectEqual(Value.empty, v);
}

test "jsonPathValue: string value" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"x\":\"hi\"}", "x", arena.allocator());
    try testing.expect(v == .string);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("hi");
    try testing.expectEqualSlices(u16, expected, v.string);
}

test "jsonPathValue: array value is error" {
    var arena = testArena();
    defer arena.deinit();
    const v = jsonPathValue("{\"x\":[1,2]}", "x", arena.allocator());
    try testing.expectEqual(Value{ .err = value_err_code }, v);
}

// --- walkJsonPath ----------------------------------------------------------

test "walkJsonPath: deeply nested" {
    var arena = testArena();
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"a\":{\"b\":{\"c\":99}}}", .{});
    const result = walkJsonPath(parsed.value, "a.b.c").?;
    try testing.expectEqual(@as(i64, 99), result.integer);
}

test "walkJsonPath: non-object intermediate" {
    var arena = testArena();
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"a\":1}", .{});
    try testing.expect(walkJsonPath(parsed.value, "a.b") == null);
}
