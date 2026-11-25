#!/usr/bin/env bash
# Samples a running Blinko process for the Phase C / PF-01…04 budgets.
#
# Usage:
#   ./Scripts/measure-app.sh [duration-seconds] [sample-interval-seconds]
#   BLINKO_PID=1234 ./Scripts/measure-app.sh 3600 10
#
# Launch the app first (`open build/Blinko.app --args --debug` is useful so the
# duty-cycle readout is visible). This script only reads process statistics;
# it never captures frames, network traffic or user data.
set -euo pipefail

duration="${1:-3600}"
interval="${2:-10}"
pid="${BLINKO_PID:-}"

if [[ -z "$pid" ]]; then
    pid="$(pgrep -x Blinko || true)"
    pid="$(printf '%s\n' "$pid" | awk 'NR == 1 { print $1 }')"
fi

if [[ -z "$pid" ]]; then
    echo "No running Blinko process found. Launch it, or set BLINKO_PID." >&2
    exit 1
fi

if ! ps -p "$pid" >/dev/null 2>&1; then
    echo "Process $pid is not running." >&2
    exit 1
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/blinko-measure.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Sampling PID $pid for ${duration}s every ${interval}s."
echo "elapsed_s  rss_mb  cpu_sample_pct  cpu_lifetime_pct"
echo "---------  ------  --------------  ----------------"

elapsed=0
while (( elapsed < duration )); do
    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "Process exited after ${elapsed}s." >&2
        break
    fi

    rss_kb="$(ps -o rss= -p "$pid" | awk '{ print $1 }')"
    cpu_lifetime="$(ps -o %cpu= -p "$pid" | awk '{ gsub(/%/, "", $1); print $1 }')"
    top_line="$(
        top -l 2 -n 1 -pid "$pid" -stats pid,cpu,mem,command \
            | awk '/^PID/ { header = 1; next } header && NF >= 3 { print; exit }'
    )"
    cpu_sample="$(printf '%s\n' "$top_line" | awk '{ gsub(/%/, "", $2); print $2 }')"

    if [[ -n "$rss_kb" && -n "$cpu_sample" && -n "$cpu_lifetime" ]]; then
        awk -v t="$elapsed" -v r="$rss_kb" -v c="$cpu_sample" -v l="$cpu_lifetime" \
            'BEGIN { printf "%9d  %6.1f  %14.1f  %16.1f\n", t, r / 1024, c, l }'
        printf '%s,%s,%s,%s\n' "$elapsed" "$rss_kb" "$cpu_sample" "$cpu_lifetime" >> "$tmp"
    fi

    sleep "$interval"
    elapsed=$(( elapsed + interval ))
done

awk -F, '
    NR == 0 { print "No samples collected."; exit }
    {
        n++
        rss_sum += $2; if ($2 > rss_max) rss_max = $2
        cpu_sum += $3; if ($3 > cpu_max) cpu_max = $3
        life_sum += $4
    }
    END {
        if (n == 0) { print "No samples collected."; exit }
        printf "\nSamples: %d\n", n
        printf "RSS:     avg %.1f MB, max %.1f MB  (budget < 50 MB)\n", rss_sum / n / 1024, rss_max / 1024
        printf "CPU:     avg %.2f%%, sampled max %.2f%%  (budget < 3%% average)\n", cpu_sum / n, cpu_max
        printf "CPU:     lifetime avg %.2f%% (ps, includes launch/setup)\n", life_sum / n
    }
' "$tmp"
