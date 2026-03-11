#!/usr/bin/env python3
"""Publish messages to stress-test subjects using NATS.

Usage:
    python publish.py                          # defaults: 200 subjects, 10 msg/s, 60s
    python publish.py --subjects 200 --rate 50 --duration 120 --payload-size 64
    python publish.py --burst 1000             # fire 1000 messages fast, then exit

Requires: nats-py (pip install nats-py)
"""

import argparse
import asyncio
import random
import signal
import sys
import time

import nats

CATEGORIES = [
    "prices", "sensors", "metrics", "orders", "events",
    "ticks", "status", "alerts", "logs", "telemetry",
]


def generate_subjects(n: int) -> list[str]:
    """Generate n unique NATS subjects across categories."""
    subjects = []
    per_cat = max(1, n // len(CATEGORIES))
    for cat in CATEGORIES:
        for i in range(per_cat):
            subjects.append(f"stress.{cat}.{i}")
            if len(subjects) >= n:
                return subjects
    while len(subjects) < n:
        cat = random.choice(CATEGORIES)
        subjects.append(f"stress.{cat}.{len(subjects)}")
    return subjects


def generate_payload() -> bytes:
    val = random.randint(0, 9999)
    dec = random.randint(0, 99)
    return f"{val}.{dec:02d}".encode()


async def burst_mode(nc: nats.NATS, subjects: list[str], count: int):
    print(f"  Mode:         burst ({count} messages)\n")
    for i in range(count):
        subj = subjects[i % len(subjects)]
        await nc.publish(subj, generate_payload())
        if (i + 1) % 100 == 0:
            await nc.flush()
            print(f"\r  Sent: {i + 1} / {count}", end="", flush=True)
    await nc.flush()
    print(f"\r  Sent: {count} / {count}")
    print("Done.")


async def steady_mode(nc: nats.NATS, subjects: list[str], rate: int, duration: int):
    total = rate * duration
    interval = 1.0 / rate
    print(f"  Mode:         steady {rate} msg/s for {duration}s ({total} total)\n")

    stopped = False

    def handle_signal():
        nonlocal stopped
        stopped = True

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, handle_signal)

    start = time.monotonic()
    for i in range(total):
        if stopped:
            print("\nStopped.")
            break

        subj = subjects[i % len(subjects)]
        await nc.publish(subj, generate_payload())

        if (i + 1) % rate == 0:
            elapsed = time.monotonic() - start
            print(f"\r  Elapsed: {elapsed:.0f}s / {duration}s  |  Sent: {i + 1} / {total}", end="", flush=True)
            await nc.flush()

        # Rate limit: sleep until next scheduled send
        next_time = start + (i + 1) * interval
        delay = next_time - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)

    await nc.flush()
    print(f"\nDone. Sent {min(i + 1, total)} messages to {len(subjects)} subjects.")


async def main():
    parser = argparse.ArgumentParser(description="NATS stress-test publisher")
    parser.add_argument("--subjects", type=int, default=200, help="Number of unique subjects (default: 200)")
    parser.add_argument("--rate", type=int, default=10, help="Messages per second (default: 10)")
    parser.add_argument("--duration", type=int, default=60, help="Seconds to run (default: 60)")
    parser.add_argument("--payload-size", type=int, default=64, help="Payload bytes (default: 64)")
    parser.add_argument("--burst", type=int, default=0, help="Send N messages fast, then exit")
    parser.add_argument("--server", default="nats://localhost:4222", help="NATS server URL")
    args = parser.parse_args()

    subject_list = generate_subjects(args.subjects)

    print("Stress test publisher")
    print(f"  Subjects:     {len(subject_list)}")
    print(f"  Payload size: {args.payload_size} bytes")

    nc = await nats.connect(args.server)
    try:
        if args.burst > 0:
            await burst_mode(nc, subject_list, args.burst)
        else:
            await steady_mode(nc, subject_list, args.rate, args.duration)
    finally:
        await nc.drain()


if __name__ == "__main__":
    asyncio.run(main())
