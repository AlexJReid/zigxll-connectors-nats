// NATS connection configuration — loaded from a JSON file at startup.
//
// Config search order (first found wins):
//   1. config.json in the same directory as the XLL
//   2. %APPDATA%\zigxll-nats\config.json
//
// If no config file is found, defaults are used (nats://127.0.0.1:4222, no auth, no TLS).

const std = @import("std");
const nats = @import("nats");
const xll = @import("xll");
const rtd = xll.rtd;
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const allocator = std.heap.c_allocator;

fn isTlsUrl(url: ?[]const u8) bool {
    const u = url orelse return false;
    return std.mem.startsWith(u8, u, "tls://");
}

pub const Config = struct {
    /// NATS server URL (e.g. "nats://host:4222"). Overridden by `servers` if set.
    url: ?[]const u8 = null,

    /// Multiple NATS server URLs for cluster failover.
    servers: ?[]const []const u8 = null,

    /// Connection name (visible in NATS monitoring).
    name: ?[]const u8 = null,

    /// Auth: username/password
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,

    /// Auth: token
    token: ?[]const u8 = null,

    /// Auth: credentials file path (JWT + NKey, as used with NATS NGS / operator mode).
    credentials_file: ?[]const u8 = null,

    /// Auth: NKey public key (the "N..." string).
    nkey_public: ?[]const u8 = null,

    /// Auth: NKey seed file path.
    nkey_seed_file: ?[]const u8 = null,

    /// TLS: enable secure connection.
    tls: bool = false,

    /// TLS: path to CA certificate file.
    tls_ca_cert: ?[]const u8 = null,

    /// TLS: path to client certificate file.
    tls_cert: ?[]const u8 = null,

    /// TLS: path to client private key file.
    tls_key: ?[]const u8 = null,

    /// TLS: skip server certificate verification (insecure, use for dev only).
    tls_skip_verify: bool = false,

    /// Connection timeout in milliseconds.
    connect_timeout_ms: ?i64 = null,

    /// Ping interval in milliseconds.
    ping_interval_ms: ?i64 = null,

    /// Max reconnect attempts (-1 for unlimited).
    max_reconnect: ?i32 = null,

    /// Reconnect wait in milliseconds.
    reconnect_wait_ms: ?i64 = null,

    /// Return the effective URL when no servers list is provided.
    pub fn effectiveUrl(self: *const Config) []const u8 {
        return self.url orelse "nats://127.0.0.1:4222";
    }
};

pub fn connectionUrl(cfg: *const Config) ![]const u8 {
    if (cfg.servers) |servers| {
        if (servers.len > 0) return allocator.dupe(u8, servers[0]);
    }
    return allocator.dupe(u8, cfg.effectiveUrl());
}

pub fn connectionOptions(cfg: *const Config) nats.Options {
    var opts = nats.Options{
        .name = cfg.name,
        .user = cfg.user,
        .pass = cfg.password,
        .auth_token = cfg.token,
        .creds_file = cfg.credentials_file,
        .nkey_seed_file = cfg.nkey_seed_file,
        .nkey_pubkey = cfg.nkey_public,
        .tls_required = cfg.tls or isTlsUrl(cfg.url),
        .tls_ca_file = cfg.tls_ca_cert,
        .tls_cert_file = cfg.tls_cert,
        .tls_key_file = cfg.tls_key,
        .tls_insecure_skip_verify = cfg.tls_skip_verify,
    };

    if (cfg.servers) |servers| {
        if (servers.len > 1) opts.servers = servers[1..];
    }
    if (cfg.connect_timeout_ms) |ms| opts.connect_timeout_ns = @as(u64, @intCast(ms)) * std.time.ns_per_ms;
    if (cfg.ping_interval_ms) |ms| opts.ping_interval_ms = @intCast(ms);
    if (cfg.max_reconnect) |max| opts.max_reconnect_attempts = if (max < 0) 0 else @intCast(max);
    if (cfg.reconnect_wait_ms) |ms| opts.reconnect_wait_ms = @intCast(ms);

    rtd.debugLog("config: official nats.zig options prepared", .{});
    return opts;
}

/// Try to load config from the search path. Returns default Config if no file found.
pub fn load() Config {
    rtd.debugLog("config: searching for config.json", .{});

    // 1. Try next to the XLL
    if (getXllDirPath()) |dir| {
        defer allocator.free(dir);
        rtd.debugLog("config: checking XLL directory '{s}'", .{dir});
        if (loadFromDir(dir)) |cfg| {
            rtd.debugLog("config: loaded from XLL directory", .{});
            return cfg;
        }
        rtd.debugLog("config: not found in XLL directory", .{});
    } else {
        rtd.debugLog("config: could not determine XLL directory", .{});
    }

    // 2. Try %APPDATA%\zigxll-nats
    if (getAppDataPath()) |dir| {
        defer allocator.free(dir);
        rtd.debugLog("config: checking APPDATA directory '{s}'", .{dir});
        if (loadFromDir(dir)) |cfg| {
            rtd.debugLog("config: loaded from APPDATA", .{});
            return cfg;
        }
        rtd.debugLog("config: not found in APPDATA directory", .{});
    } else {
        rtd.debugLog("config: could not determine APPDATA path", .{});
    }

    rtd.debugLog("config: no config file found, using defaults (nats://127.0.0.1:4222, no auth, no TLS)", .{});
    return .{};
}

fn loadFromDir(dir: []const u8) ?Config {
    const path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{dir}) catch return null;
    defer allocator.free(path);
    return loadFromFile(path);
}

fn loadFromFile(path: []const u8) ?Config {
    const pathz = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(pathz);

    rtd.debugLog("config: trying to open '{s}'", .{pathz});

    // Use Win32 API directly — std.fs can be unreliable in cross-compiled XLL context.
    const handle = win.CreateFileA(
        pathz.ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win.INVALID_HANDLE_VALUE) {
        rtd.debugLog("config: could not open '{s}'", .{pathz});
        return null;
    }
    defer _ = win.CloseHandle(handle);

    const file_size = win.GetFileSize(handle, null);
    if (file_size == win.INVALID_FILE_SIZE or file_size == 0 or file_size > 64 * 1024) {
        rtd.debugLog("config: invalid file size {d} for '{s}'", .{ file_size, pathz });
        return null;
    }

    const content = allocator.alloc(u8, file_size) catch return null;
    defer allocator.free(content);

    var bytes_read: win.DWORD = 0;
    const read_ok = win.ReadFile(handle, content.ptr, file_size, &bytes_read, null);
    if (read_ok == 0 or bytes_read != file_size) {
        rtd.debugLog("config: could not read '{s}'", .{pathz});
        return null;
    }

    rtd.debugLog("config: parsing '{s}' ({d} bytes)", .{ pathz, content.len });

    const parsed = std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        rtd.debugLog("config: JSON parse error in '{s}': {s}", .{ pathz, @errorName(err) });
        return null;
    };

    // Intentionally leak — config lives for the duration of the process.
    rtd.debugLog("config: successfully parsed config from '{s}'", .{pathz});
    return parsed.value;
}

fn getXllDirPath() ?[]const u8 {
    // Use GetModuleHandleExA with FROM_ADDRESS to find the module containing
    // this function — gives us the XLL's HMODULE, not the host exe.
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x04;
    const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x02;
    var hmod: win.HMODULE = null;
    const ok = win.GetModuleHandleExA(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrCast(&getXllDirPath),
        &hmod,
    );
    if (ok == 0) {
        rtd.debugLog("config: GetModuleHandleExA failed", .{});
        return null;
    }

    var buf: [win.MAX_PATH]u8 = undefined;
    const len = win.GetModuleFileNameA(hmod, &buf, win.MAX_PATH);
    if (len == 0) {
        rtd.debugLog("config: GetModuleFileNameA failed", .{});
        return null;
    }

    const full = buf[0..len];
    rtd.debugLog("config: XLL path is '{s}'", .{full});
    const idx = std.mem.lastIndexOfScalar(u8, full, '\\') orelse return null;
    return allocator.dupe(u8, full[0..idx]) catch null;
}

fn getAppDataPath() ?[]const u8 {
    var buf: [win.MAX_PATH]u8 = undefined;
    const len = win.GetEnvironmentVariableA("APPDATA", &buf, win.MAX_PATH);
    if (len == 0) {
        rtd.debugLog("config: APPDATA environment variable not set", .{});
        return null;
    }

    const appdata = buf[0..len];
    return std.fmt.allocPrint(allocator, "{s}\\zigxll-nats", .{appdata}) catch null;
}
