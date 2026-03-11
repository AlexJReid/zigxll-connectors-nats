# NATS RTD Stress Test

See it running: https://youtu.be/iCftl9E8PK0

Tools for stress testing the NATS Excel XLL add-in with many concurrent RTD subscriptions.

## Overview

- **`generate_workbook.py`** - Generates an `.xlsx` with hundreds of `=NATS.SUB()` formulas across multiple sheets, including deliberate duplicates to exercise shared subscription paths.
- **`publish.py`** - Publishes messages to the matching NATS subjects at a configurable rate using the `nats-py` async client.
- **`stress-test.xlsx`** - Pre-generated workbook (200 unique subjects, 500 total RTD cells, ~60% duplicates).

## Setup

```bash
cd stress-test
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Recommended test setup

Run Excel with the XLL add-in on a **separate Windows machine** (or VM) from the publisher. This avoids the publisher competing for CPU/memory with Excel and gives more realistic results. Both machines need network access to the same NATS server.

Typical topology:

```
[Publisher machine]  -->  [NATS server]  <--  [Windows + Excel + XLL]
```

If testing locally on one Windows box, keep in mind that the publisher and Excel will share resources, which can skew results.

## Generate the workbook

```bash
# Defaults: 200 unique subjects, 500 cells
source .venv/bin/activate
python generate_workbook.py

# Custom: more subjects, more cells
python generate_workbook.py --subjects 500 --cells 2000 --output big-test.xlsx
```

The workbook contains three sheets:
- **Stress Test** - Grid of `=NATS.SUB("stress.{category}.{id}")` formulas (10 columns).
- **Info** - Summary of parameters.
- **By Category** - All unique subjects sorted by category, one per row.

## Publish messages

```bash
source .venv/bin/activate

# Steady rate: 10 msg/s for 60 seconds (default)
python publish.py

# Higher rate, longer duration
python publish.py --rate 100 --duration 300

# Burst: fire 1000 messages as fast as possible
python publish.py --burst 1000

# Target a remote NATS server
python publish.py --server nats://192.168.1.50:4222
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--subjects` | 200 | Unique subjects (must match workbook) |
| `--rate` | 10 | Messages per second |
| `--duration` | 60 | Seconds to run |
| `--payload-size` | 64 | Payload size in bytes |
| `--burst` | 0 | Send N messages fast, then exit |
| `--server` | `nats://localhost:4222` | NATS server URL |

### Payload format

Each message is a decimal number string, e.g. `4821.07`.

## What to look for

- **Cell update latency** - Do cells update promptly or lag behind?
- **Excel responsiveness** - Can you still scroll/interact while cells are updating?
- **Memory usage** - Does Excel's memory grow unbounded over time?
- **Missed updates** - After stopping the publisher, do all cells show the final values?
- **Duplicate handling** - Cells subscribing to the same subject should show identical values.
- **Recovery** - Stop and restart the publisher; cells should resume updating.

## Prerequisites

- Python 3.10+
- `pip install -r requirements.txt` (installs `openpyxl` and `nats-py`)
- A running NATS server accessible from both publisher and Excel machines
