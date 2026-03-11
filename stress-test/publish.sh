#!/usr/bin/env bash
#
# Publish messages to stress-test subjects using nats CLI.
#
# Usage:
#   ./publish.sh                          # defaults: 200 subjects, 10 msg/s total, 60s
#   ./publish.sh --subjects 200 --rate 50 --duration 120 --payload-size 64
#   ./publish.sh --burst 1000             # fire 1000 messages as fast as possible, then exit
#
# Requires: nats CLI (https://github.com/nats-io/natscli)

set -euo pipefail

SUBJECTS=200
RATE=10          # messages per second (total across all subjects, round-robin)
DURATION=60      # seconds
PAYLOAD_SIZE=64  # bytes of random-ish payload
BURST=0          # if >0, send this many msgs fast and exit (ignores RATE/DURATION)
NATS_URL=""      # empty = use nats CLI default (localhost:4222)
CATEGORIES=(prices sensors metrics orders events ticks status alerts logs telemetry)

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --subjects N       Number of unique subjects (default: $SUBJECTS)"
    echo "  --rate N           Messages per second (default: $RATE)"
    echo "  --duration N       Seconds to run (default: $DURATION)"
    echo "  --payload-size N   Payload bytes (default: $PAYLOAD_SIZE)"
    echo "  --burst N          Send N messages fast, then exit (overrides rate/duration)"
    echo "  --server URL       NATS server URL (default: nats CLI default)"
    echo "  -h, --help         Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subjects)     SUBJECTS="$2"; shift 2 ;;
        --rate)         RATE="$2"; shift 2 ;;
        --duration)     DURATION="$2"; shift 2 ;;
        --payload-size) PAYLOAD_SIZE="$2"; shift 2 ;;
        --burst)        BURST="$2"; shift 2 ;;
        --server)       NATS_URL="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Build subject list (must match generate_workbook.py pattern)
build_subjects() {
    local n=$1
    local count=0
    local per_cat=$(( (n + ${#CATEGORIES[@]} - 1) / ${#CATEGORIES[@]} ))
    for cat in "${CATEGORIES[@]}"; do
        for ((i = 0; i < per_cat && count < n; i++, count++)); do
            echo "stress.${cat}.${i}"
        done
    done
}

mapfile -t SUBJECT_LIST < <(build_subjects "$SUBJECTS")
NATS_ARGS=()
[[ -n "$NATS_URL" ]] && NATS_ARGS+=(--server "$NATS_URL")

echo "Stress test publisher"
echo "  Subjects:     ${#SUBJECT_LIST[@]}"
echo "  Payload size: ${PAYLOAD_SIZE} bytes"

generate_payload() {
    # JSON-ish payload with timestamp and random value
    local subj="$1"
    local seq="$2"
    local ts
    ts=$(date +%s%3N 2>/dev/null || date +%s)
    # Generate a random float-like value
    local val=$((RANDOM % 10000))
    local dec=$((RANDOM % 100))
    printf '{"subject":"%s","seq":%d,"ts":%s,"value":%d.%02d}' "$subj" "$seq" "$ts" "$val" "$dec"
}

if [[ "$BURST" -gt 0 ]]; then
    echo "  Mode:         burst ($BURST messages)"
    echo ""
    seq_num=0
    for ((i = 0; i < BURST; i++)); do
        idx=$((i % ${#SUBJECT_LIST[@]}))
        subj="${SUBJECT_LIST[$idx]}"
        payload=$(generate_payload "$subj" "$seq_num")
        nats pub "${NATS_ARGS[@]}" "$subj" "$payload" >/dev/null 2>&1 &
        seq_num=$((seq_num + 1))
        # batch: run up to 50 in parallel, then wait
        if (( (i + 1) % 50 == 0 )); then
            wait
            echo -ne "\r  Sent: $((i + 1)) / $BURST"
        fi
    done
    wait
    echo -e "\r  Sent: $BURST / $BURST"
    echo "Done."
    exit 0
fi

# Steady-rate mode
INTERVAL_US=$(( 1000000 / RATE ))
TOTAL_MSGS=$(( RATE * DURATION ))
echo "  Mode:         steady ${RATE} msg/s for ${DURATION}s (${TOTAL_MSGS} total)"
echo ""

cleanup() {
    echo -e "\nStopped."
    exit 0
}
trap cleanup INT TERM

seq_num=0
start_time=$(date +%s)
for ((i = 0; i < TOTAL_MSGS; i++)); do
    idx=$((i % ${#SUBJECT_LIST[@]}))
    subj="${SUBJECT_LIST[$idx]}"
    payload=$(generate_payload "$subj" "$seq_num")
    nats pub "${NATS_ARGS[@]}" "$subj" "$payload" >/dev/null 2>&1
    seq_num=$((seq_num + 1))

    if (( (i + 1) % RATE == 0 )); then
        elapsed=$(( $(date +%s) - start_time ))
        echo -ne "\r  Elapsed: ${elapsed}s / ${DURATION}s  |  Sent: $((i + 1)) / ${TOTAL_MSGS}"
    fi

    # Crude rate limiting — sleep in microseconds if available
    if command -v usleep &>/dev/null; then
        usleep "$INTERVAL_US"
    else
        sleep "$(awk "BEGIN{printf \"%.4f\", $INTERVAL_US/1000000}")"
    fi
done

echo ""
echo "Done. Sent $TOTAL_MSGS messages to ${#SUBJECT_LIST[@]} subjects."
