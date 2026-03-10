# zigxll-connectors-nats

A NATS connector for Excel built with [ZigXLL](https://github.com/AlexJReid/zigxll). Subscribes to NATS subjects and streams published messages into Excel cells via RTD.

[Introductory blog post](https://alexjreid.dev/posts/zigxll/)

> **Proof of concept.** This is an experimental demo of what's possible with ZigXLL's RTD support. It connects to a hardcoded localhost NATS server (`127.0.0.1:4222`) with no authentication, TLS, or reconnect handling. Not intended for production use yet.

[![Demo video](https://img.youtube.com/vi/sWCvkbp4RcA/maxresdefault.jpg)](https://youtu.be/sWCvkbp4RcA)

## Why

- **Single small binary** (~370KB `.xll` file), nothing to install. Just open it in Excel.
- **No .NET, no VSTO, no COM boilerplate.** The RTD server registers itself to `HKCU` on load, no admin rights needed.
- **Custom Excel functions** like `=NATS.SUB("prices.gbp")` so users never need to think about raw `=RTD(...)` syntax.
- **Built on [nats.c](https://github.com/nats-io/nats.c)**, a mature, battle-tested NATS client. Not a toy reimplementation.
- **Designed for throughput.** Arena-allocated refresh cycles, zero per-message allocations on the render path, and lock-free handoff from the nats.c thread pool to Excel's RTD polling.

## Usage in Excel

```
=NATS.SUB("my.subject")
```

Or the raw RTD call:

```
=RTD("zigxll.connectors.nats", , "my.subject")
```

Requires a NATS server running on `127.0.0.1:4222`.

### RTD throttle interval

Excel throttles RTD updates via `Application.RTD.ThrottleInterval`, which defaults to 2000ms. For higher update rates, lower it in the VBA Immediate Window (`Alt+F11`, then `Ctrl+G`):

```vb
Application.RTD.ThrottleInterval = 100
```

Set to `0` for the fastest possible updates. This setting persists across sessions.

## Building

### Cross-compilation setup

Although Excel XLL assemblies only run on Windows, ZigXLL cross-compiles Windows XLL add-ins from macOS or Linux with the help of [xwin](https://jake-shadle.github.io/xwin/).

**Windows:** Skip this section.

**macOS:**
```bash
brew install xwin
xwin --accept-license splat --output ~/.xwin
```

**Linux:**
```bash
cargo install xwin
xwin --accept-license splat --output ~/.xwin
```

If Cargo isn't available, install Rust via [rustup.rs](https://rustup.rs/) or download a prebuilt binary from the [xwin releases page](https://github.com/Jake-Shadle/xwin/releases).

See the [ZigXLL README](https://github.com/AlexJReid/zigxll) for more details.

### Build the XLL

```bash
zig build
```

The XLL will be output to `zig-out/lib/zigxll-connectors-nats.xll`.

## RTD Servers

| ProgID | CLSID | Description |
|--------|-------|-------------|
| `zigxll.connectors.nats` | `{A1B2C3D4-E5F6-7890-ABCD-EF0123456789}` | Subscribe to NATS subjects |

RTD servers are registered automatically when the XLL is loaded into Excel (writes to `HKCU\Software\Classes`, no admin needed).

## Excel Functions

| Function | Description |
|----------|-------------|
| `=NATS.SUB("subject")` | Subscribe to a NATS subject (RTD wrapper) |
| `=NATS.SUB("subject", "type")` | Subscribe with a type hint (see below) |

### Type hints

The optional second argument to `NATS.SUB` controls how the received payload is interpreted:

| Usage | Behavior |
|---|---|
| `=NATS.SUB("prices.BTC")` | Auto: duck-types — tries bool, int, float, falls back to string |
| `=NATS.SUB("prices.BTC", "number")` | Forces numeric coercion, `#VALUE!` if not parseable |
| `=NATS.SUB("flags.active", "bool")` | Forces bool (`"true"`/`"false"`), `#VALUE!` otherwise |
| `=NATS.SUB("data.raw", "string")` | Always string, no coercion |
| `=NATS.SUB("ticker.AAPL", "$.price")` | Parses JSON payload, extracts `price` field, type from JSON |
| `=NATS.SUB("ticker.AAPL", "$.quote.last")` | Nested dot-path: `{"quote":{"last":142.5}}` → `142.5` as double |

When omitted, the default is `auto` — values that look like numbers or booleans are returned as native Excel types, enabling direct use in formulas and charts without manual conversion.

## Architecture

The XLL embeds a vendored copy of [nats.c](https://github.com/nats-io/nats.c), compiled as a static library. This required some patches to work in the Zig XLL build environment (bypassing `InitOnceExecuteOnce` and `atexit` which deadlock without a full MSVC CRT). It may be possible to use nats.c as a Zig build system dependency instead of vendoring, but this hasn't been explored yet. Messages arrive on nats.c's internal thread pool via a subscription callback, which stores the latest value per topic and notifies Excel to refresh.

Key implementation details:

- **Arena allocator** for UTF-16 string conversions during Excel refresh cycles -reset once per `RefreshData` batch, zero malloc/free churn on the hot path
- **Null-terminated subject copies** when passing Zig slices to the nats.c C API
- **CRT compatibility patches** for the Zig XLL build environment -`InitOnceExecuteOnce` and `atexit()` are bypassed as they can deadlock in DLLs built with Zig's CRT stubs

## Try out the pre-built XLL

1. Download the latest release (Windows only)
2. Scroll down to the very bottom and download the **zigxll-connectors-nats** artifact
3. Extract the XLL file from the zip to a safe location -desktop works
4. You will need to unblock it. More info: [Excel is blocking untrusted XLL add-ins](https://support.microsoft.com/en-gb/topic/excel-is-blocking-untrusted-xll-add-ins-by-default-1e3752e2-1177-4444-a807-7b700266a6fb)
5. Double-click `zigxll-connectors-nats.xll` to load it into Excel

## Roadmap

This is a proof of concept. The following are areas for future development:

- **Authentication:** support for NATS token, user/password, and NKey/credentials-based auth
- **TLS:** encrypted connections to NATS servers
- **Configurable server addresses:** expose a subset of nats.c connection options instead of hardcoded `127.0.0.1:4222`
- **JetStream:** subscribe to JetStream consumers for durable, replay-capable streams with at-least-once delivery
- **Last value population:** populate cells with the most recent value on subscribe, so sheets aren't empty until the next publish
- **~~Lightweight transforms~~:** ✅ type hints and JSON dot-path extraction are now supported via the second argument to `NATS.SUB`
- **Debouncing/windowing:** reduce unnecessary recalculations, e.g. round to 3 decimal places and only update the cell if the rounded value differs
- **Publish support:** `=NATS.PUB("subject", value)` to publish messages back to NATS from Excel
- **Reconnect handling:** graceful reconnection with backoff when the NATS server is unavailable or restarts

## License

MIT. See [LICENSE](LICENSE) for details.

This project uses [nats.c](https://github.com/nats-io/nats.c) (Apache 2.0) and [ZigXLL](https://github.com/AlexJReid/zigxll) (MIT). See [NOTICE](NOTICE) for attribution.


