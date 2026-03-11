// NATS connection configuration — loaded from a JSON file at startup.
//
// Config search order (first found wins):
//   1. config.json in the same directory as the XLL
//   2. %APPDATA%\zigxll-nats\config.json
//
// If no config file is found, defaults are used (nats://127.0.0.1:4222, no auth, no TLS).

const std = @import("std");
const nats = @cImport(@cInclude("nats.h"));
const xll = @import("xll");
const rtd = xll.rtd;
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const allocator = std.heap.c_allocator;

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

/// Apply config to a natsOptions handle. Accepts *anyopaque to avoid
/// cross-cImport opaque type mismatches — caller passes their natsOptions ptr.
pub fn applyOptions(opts_opaque: *anyopaque, cfg: *const Config) c_int {
    const opts: *nats.natsOptions = @ptrCast(opts_opaque);
    var s: nats.natsStatus = nats.NATS_OK;

    // Server URL(s)
    if (cfg.servers) |servers| {
        if (servers.len > 0) {
            rtd.debugLog("config: setting {d} server URLs", .{servers.len});
            const ptrs = allocator.alloc([*c]const u8, servers.len) catch return nats.NATS_NO_MEMORY;
            defer allocator.free(ptrs);
            const zstrs = allocator.alloc([:0]const u8, servers.len) catch return nats.NATS_NO_MEMORY;
            defer {
                for (zstrs) |z| allocator.free(z);
                allocator.free(zstrs);
            }
            for (servers, 0..) |srv, i| {
                zstrs[i] = allocator.dupeZ(u8, srv) catch return nats.NATS_NO_MEMORY;
                ptrs[i] = zstrs[i].ptr;
                rtd.debugLog("config:   server[{d}] = {s}", .{ i, zstrs[i] });
            }
            s = nats.natsOptions_SetServers(opts, @ptrCast(ptrs.ptr), @intCast(servers.len));
            if (s != nats.NATS_OK) {
                rtd.debugLog("config: natsOptions_SetServers failed status={d}", .{s});
                return s;
            }
        }
    } else if (cfg.url) |url| {
        rtd.debugLog("config: setting URL to '{s}'", .{url});
        const z = allocator.dupeZ(u8, url) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(z);
        s = nats.natsOptions_SetURL(opts, z.ptr);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetURL failed status={d}", .{s});
            return s;
        }
    } else {
        rtd.debugLog("config: no URL configured, will use nats.c default", .{});
    }

    // Connection name
    if (cfg.name) |name| {
        rtd.debugLog("config: setting connection name to '{s}'", .{name});
        const z = allocator.dupeZ(u8, name) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(z);
        s = nats.natsOptions_SetName(opts, z.ptr);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetName failed status={d}", .{s});
            return s;
        }
    }

    // Auth: user/password
    if (cfg.user) |user| {
        rtd.debugLog("config: setting user/password auth (user='{s}')", .{user});
        const uz = allocator.dupeZ(u8, user) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(uz);
        const pz = if (cfg.password) |p|
            allocator.dupeZ(u8, p) catch return nats.NATS_NO_MEMORY
        else
            null;
        defer if (pz) |p| allocator.free(p);
        s = nats.natsOptions_SetUserInfo(opts, uz.ptr, if (pz) |p| p.ptr else null);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetUserInfo failed status={d}", .{s});
            return s;
        }
    }

    // Auth: token
    if (cfg.token) |_| {
        rtd.debugLog("config: setting token auth", .{});
        const z = allocator.dupeZ(u8, cfg.token.?) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(z);
        s = nats.natsOptions_SetToken(opts, z.ptr);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetToken failed status={d}", .{s});
            return s;
        }
    }

    // Auth: credentials file
    if (cfg.credentials_file) |creds| {
        rtd.debugLog("config: setting credentials file '{s}'", .{creds});
        const z = allocator.dupeZ(u8, creds) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(z);
        s = nats.natsOptions_SetUserCredentialsFromFiles(opts, z.ptr, null);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetUserCredentialsFromFiles failed status={d}", .{s});
            return s;
        }
    }

    // Auth: NKey (public key + seed file)
    if (cfg.nkey_seed_file) |seed| {
        const pub_key = cfg.nkey_public orelse {
            rtd.debugLog("config: nkey_seed_file set but nkey_public is missing", .{});
            return nats.NATS_ERR;
        };
        rtd.debugLog("config: setting NKey auth (pubkey='{s}', seed='{s}')", .{ pub_key, seed });
        const pz = allocator.dupeZ(u8, pub_key) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(pz);
        const sz = allocator.dupeZ(u8, seed) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(sz);
        s = nats.natsOptions_SetNKeyFromSeed(opts, pz.ptr, sz.ptr);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetNKeyFromSeed failed status={d}", .{s});
            return s;
        }
    }

    // TLS
    if (cfg.tls) {
        rtd.debugLog("config: enabling TLS", .{});
        s = nats.natsOptions_SetSecure(opts, true);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetSecure failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.tls_ca_cert) |ca| {
        rtd.debugLog("config: loading CA cert from '{s}'", .{ca});
        const z = allocator.dupeZ(u8, ca) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(z);
        s = nats.natsOptions_LoadCATrustedCertificates(opts, z.ptr);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_LoadCATrustedCertificates failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.tls_cert) |cert| {
        rtd.debugLog("config: loading client cert from '{s}'", .{cert});
        const cz = allocator.dupeZ(u8, cert) catch return nats.NATS_NO_MEMORY;
        defer allocator.free(cz);
        const kz = if (cfg.tls_key) |k|
            allocator.dupeZ(u8, k) catch return nats.NATS_NO_MEMORY
        else
            null;
        defer if (kz) |k| allocator.free(k);
        if (cfg.tls_key) |key| {
            rtd.debugLog("config: loading client key from '{s}'", .{key});
        }
        s = nats.natsOptions_LoadCertificatesChain(opts, cz.ptr, if (kz) |k| k.ptr else null);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_LoadCertificatesChain failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.tls_skip_verify) {
        rtd.debugLog("config: WARNING skipping TLS server verification", .{});
        s = nats.natsOptions_SkipServerVerification(opts, true);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SkipServerVerification failed status={d}", .{s});
            return s;
        }
    }

    // Timeouts and reconnect
    if (cfg.connect_timeout_ms) |t| {
        rtd.debugLog("config: setting connect timeout to {d}ms", .{t});
        s = nats.natsOptions_SetTimeout(opts, t);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetTimeout failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.ping_interval_ms) |p| {
        rtd.debugLog("config: setting ping interval to {d}ms", .{p});
        s = nats.natsOptions_SetPingInterval(opts, p);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetPingInterval failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.max_reconnect) |m| {
        rtd.debugLog("config: setting max reconnect to {d}", .{m});
        s = nats.natsOptions_SetMaxReconnect(opts, m);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetMaxReconnect failed status={d}", .{s});
            return s;
        }
    }

    if (cfg.reconnect_wait_ms) |r| {
        rtd.debugLog("config: setting reconnect wait to {d}ms", .{r});
        s = nats.natsOptions_SetReconnectWait(opts, r);
        if (s != nats.NATS_OK) {
            rtd.debugLog("config: natsOptions_SetReconnectWait failed status={d}", .{s});
            return s;
        }
    }

    rtd.debugLog("config: all options applied successfully", .{});
    return nats.NATS_OK;
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
