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

The default target is `x86_64-windows-msvc`, producing a Windows XLL. Native Windows builds and macOS/Linux cross-compilation use the same fetch, patch, and build sequence documented in the README.

**Zig version:** 0.16.0

## Dependencies

- **ZigXLL framework:** Referenced from `build.zig.zon`.
- **nats.zig:** Official Zig NATS client, referenced from `build.zig.zon`.

## Architecture

### Entry point and registration (`src/main.zig`)

Declares `function_modules` and `rtd_servers` — tuples of imported modules that ZigXLL uses to auto-register Excel functions and COM RTD servers at load time.

### RTD servers

RTD servers implement a handler struct with lifecycle callbacks (`onStart`, `onConnect`, `onDisconnect`, `onRefreshValue`, `onTerminate`) and a `rtd_config` with CLSID + ProgID. ZigXLL wraps these via `rtd.RtdServer(Handler, config)`.

- **`src/nats_rtd.zig`** — The core NATS RTD server. Connects to NATS on start, subscribes per Excel cell topic using nats.zig callback subscriptions. Messages are stored in a mutex-protected hash map keyed by topic_id. `onRefreshValue` converts UTF-8 payloads to UTF-16 using a per-batch arena allocator (reset in `onBeforeRefresh`).
- **`src/timer_rtd.zig`** — Simple demo RTD server that ticks a counter every 2 seconds.

### Excel functions (`src/functions.zig`)

Wrapper functions (`NATS.SUB`, `TIMER`) that call `xll.rtd_call.subscribe()` so users don't need raw `=RTD(...)` formulas.

### NATS integration

- **nats.zig integration** — Imported as the `nats` Zig package. TLS uses Zig/std support; there is no OpenSSL or C client build path.

### Threading model

nats.zig callback subscriptions deliver messages asynchronously. The callback takes a mutex, updates `values` map, marks the topic dirty, and calls `ctx.notifyExcel()`. Excel's RTD polling then calls `onRefreshValue` on Excel's thread.

## CI

GitHub Actions workflow (`.github/workflows/build.yml`) builds on `windows-latest` natively, sets up MSVC and Zig 0.16.0, runs `zig build`, signs the XLL, and uploads it as an artifact.
