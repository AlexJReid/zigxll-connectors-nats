# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A NATS connector for Excel, built as an XLL add-in using the [ZigXLL](https://github.com/AlexJReid/zigxll) framework. It subscribes to NATS subjects and streams messages into Excel cells via RTD (Real-Time Data). Supports configurable server addresses, authentication (token, user/password, NKey, credentials file), and TLS. Defaults to `127.0.0.1:4222` with no auth/TLS when no config file is present.

## Build

```bash
zig build
```

Output: `zig-out/lib/zigxll-connectors-nats.xll`

### Format

```bash
zig fmt src/          # format in-place
zig fmt --check src/  # check only (CI-friendly, exits non-zero if unformatted)
```

**Cross-compilation from macOS/Linux** requires [xwin](https://jake-shadle.github.io/xwin/) with SDK splatted to `~/.xwin`. The default target is `x86_64-windows-msvc`. No native build target exists — this always produces a Windows DLL.

**Zig version:** 0.16.0

## Dependencies

- **ZigXLL framework:** Referenced as a path dependency at `../zigxll` in `build.zig.zon`. Must be cloned as a sibling directory.
- **nats.c (vendored):** Placed at `vendor/nats.c/`. Not checked into git — CI fetches v3.12.0 from GitHub. Locally, use `bump-dep.sh` or manually extract the tarball.

## Architecture

### Entry point and registration (`src/main.zig`)

Declares `function_modules` and `rtd_servers` — tuples of imported modules that ZigXLL uses to auto-register Excel functions and COM RTD servers at load time.

### RTD servers

RTD servers implement a handler struct with lifecycle callbacks (`onStart`, `onConnect`, `onDisconnect`, `onRefreshValue`, `onTerminate`) and a `rtd_config` with CLSID + ProgID. ZigXLL wraps these via `rtd.RtdServer(Handler, config)`.

- **`src/nats_rtd.zig`** — The core NATS RTD server. Connects to NATS on start, subscribes per Excel cell topic. Messages arrive on nats.c's internal thread pool via `onMsg` callback (C calling convention), stored in a mutex-protected hash map keyed by topic_id. `onRefreshValue` converts UTF-8 payloads to UTF-16 using a per-batch arena allocator (reset in `onBeforeRefresh`).
- **`src/timer_rtd.zig`** — Simple demo RTD server that ticks a counter every 2 seconds.

### Excel functions (`src/functions.zig`)

Wrapper functions (`NATS.SUB`, `TIMER`) that call `xll.rtd_call.subscribe()` so users don't need raw `=RTD(...)` formulas.

### C interop

- **nats.c integration** — Compiled as static C sources directly in `build.zig` (not as a separate library). Zig code uses `@cImport(@cInclude("nats.h"))`. Key flags: `-D_REENTRANT -DNATS_STATIC`. TLS is supported via `-Dtls=true` build option (links OpenSSL). No streaming.

### Threading model

nats.c runs its own thread pool. The `onMsg` callback fires on those threads, takes a mutex, updates `values` map, marks the topic dirty, and calls `ctx.notifyExcel()`. Excel's RTD polling then calls `onRefreshValue` on Excel's thread.

## CI

GitHub Actions workflow (`.github/workflows/build.yml`) builds on `windows-latest` natively (no cross-compilation). Fetches nats.c, sets up MSVC and Zig 0.15.1, runs `zig build`, uploads the XLL as an artifact.
