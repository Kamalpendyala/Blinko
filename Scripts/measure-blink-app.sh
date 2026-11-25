#!/usr/bin/env bash
# Samples the whole Blink.app process tree (Electron main process + helpers) for
# the same CPU/RAM figures as measure-app.sh, so the two apps can be compared.
#
# Usage:
#   ./Scripts/measure-blink-app.sh [duration-seconds] [sample-interval-seconds]
#   BLINK_PID=1234 ./Scripts/measure-blink-app.sh 150 5
#   BLINK_BREAKDOWN=1 ./Scripts/measure-blink-app.sh 150 5
#
# Launch the app first: `open /Applications/Blink.app` (you may need to approve
# the camera permission prompt once). This script only reads process statistics;
# it never captures frames, network traffic or user data.
#
# `cpu_sample_pct` is the interval CPU usage derived from cumulative CPU-time
# deltas (the same metric `top` reports per process). One `top -l 2` call per
# Electron helper costs ~1.6 s, which is too slow for short sample intervals.
# `cpu_lifetime_pct` is `ps -o %cpu=`, which includes launch/setup. The first
# sample has no previous timestamp, so it is excluded from the CPU average.
set -euo pipefail

duration="${1:-150}"
interval="${2:-5}"
app_path="${BLINK_APP_PATH:-/Applications/Blink.app}"
pid_override="${BLINK_PID:-}"
breakdown="${BLINK_BREAKDOWN:-0}"

die() {
    echo "$*" >&2
    exit 1
}

[[ "$duration" =~ ^[0-9]+$ ]] || die "duration must be a whole number of seconds"
[[ "$interval" =~ ^[0-9]+$ ]] || die "interval must be a whole number of seconds"
(( interval > 0 )) || die "interval must be greater than zero"

app_path="${app_path%/}"
[[ -d "$app_path" ]] || die "App bundle not found: $app_path"

# High-resolution wall clock for CPU-time deltas (perl ships with macOS).
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# Escapes a literal path for use in an extended-regex match.
escape_regex() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//./\\.}"
    s="${s//+/\\+}"
    s="${s//(/\\(}"
    s="${s//)/\\)}"
    s="${s//[//\\[}"
    s="${s//]//\\]}"
    s="${s//?/\\?}"
    s="${s//*/\\*}"
    s="${s//^/\\^}"
    s="${s//$/\\$}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}

# Prints the PIDs of every live process belonging to the app bundle. When
# BLINK_PID is set it is treated as an explicit, comma/space separated list.
collect_pids() {
    local raw pid cmd out=""
    if [[ -n "$pid_override" ]]; then
        raw="${pid_override//,/ }"
    else
        raw="$(pgrep -f "$(escape_regex "$app_path")" || true)"
    fi

    for pid in $raw; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        ps -p "$pid" >/dev/null 2>&1 || continue
        if [[ -z "$pid_override" ]]; then
            cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
            [[ "$cmd" == *"$app_path"* ]] || continue
        fi
        out+=" $pid"
    done
    printf '%s' "${out# }"
}

pids="$(collect_pids)"
[[ -n "$pids" ]] || die "No running Blink processes found. Launch it with: open \"$app_path\""

tmp="$(mktemp "${TMPDIR:-/tmp}/blink-measure.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Sampling $app_path (all processes) for ${duration}s every ${interval}s."
echo "Budget lines are Blinko's targets (< 50 MB RSS, < 3% CPU), for comparison."
echo "elapsed_s  rss_mb  cpu_sample_pct  cpu_lifetime_pct"
echo "---------  ------  --------------  ----------------"

elapsed=0
prev_ts=""
declare -a prev_pids=() prev_secs=()
declare -A sec_by_pid=()

while (( elapsed < duration )); do
    pids="$(collect_pids)"
    if [[ -z "$pids" ]]; then
        echo "No Blink processes left after ${elapsed}s." >&2
        break
    fi

    ts="$(now)"
    pid_csv="$(IFS=,; echo "${pids// /,}")"

    # One ps call for RSS / lifetime CPU / command, one for cumulative CPU time.
    stat_rows="$(ps -o pid=,rss=,%cpu=,comm= -p "$pid_csv" 2>/dev/null || true)"
    time_rows="$(ps -o pid=,time= -p "$pid_csv" 2>/dev/null | awk '{
        t = $2
        days = 0
        if (index(t, "-")) {
            split(t, dpart, "-"); days = dpart[1]; t = dpart[2]
        }
        n = split(t, parts, ":")
        sec = 0
        for (i = 1; i <= n; i++) sec = sec * 60 + parts[i]
        print $1, days * 86400 + sec
    }' || true)"

    sec_by_pid=()
    declare -a cur_pids=() cur_rss=() cur_life=() cur_comm=() cur_sample=()
    while read -r p r l c; do
        [[ -n "$p" ]] || continue
        cur_pids+=("$p")
        cur_rss+=("$r")
        cur_life+=("$l")
        cur_comm+=("${c##*/}")
    done <<< "$stat_rows"

    # Key CPU seconds by PID: helpers can exit between the two `ps` calls, so
    # pairing the rows by position would attribute one process's CPU to another.
    while read -r p s; do
        [[ -n "$p" ]] || continue
        sec_by_pid["$p"]="$s"
    done <<< "$time_rows"

    # Match PIDs between samples (helpers can come and go) and turn CPU-time
    # deltas into a whole-app instantaneous CPU percentage.
    rss_total=0
    life_total=0
    cpu_sample=0
    cpu_valid=0
    [[ -n "$prev_ts" ]] && cpu_valid=1
    for i in "${!cur_pids[@]}"; do
        rss_total="$(awk -v a="$rss_total" -v b="${cur_rss[$i]}" 'BEGIN { print a + b }')"
        life_total="$(awk -v a="$life_total" -v b="${cur_life[$i]}" 'BEGIN { print a + b }')"

        sample_now=0
        sec="${sec_by_pid[${cur_pids[$i]}]-}"
        if [[ -n "$sec" && -n "$prev_ts" ]]; then
            for j in "${!prev_pids[@]}"; do
                if [[ "${prev_pids[$j]}" == "${cur_pids[$i]}" ]]; then
                    delta="$(awk -v a="$sec" -v b="${prev_secs[$j]}" 'BEGIN { print a - b }')"
                    wall="$(awk -v a="$ts" -v b="$prev_ts" 'BEGIN { if (a - b <= 0) print 0.001; else print a - b }')"
                    sample_now="$(awk -v d="$delta" -v w="$wall" 'BEGIN { if (d < 0) d = 0; printf "%.3f", d / w * 100 }')"
                    break
                fi
            done
        fi
        cur_sample+=("$sample_now")
        cpu_sample="$(awk -v a="$cpu_sample" -v b="$sample_now" 'BEGIN { print a + b }')"
    done

    if (( ${#cur_pids[@]} > 0 )); then
        awk -v t="$elapsed" -v r="$rss_total" -v c="$cpu_sample" -v l="$life_total" \
            'BEGIN { printf "%9d  %6.1f  %14.1f  %16.1f\n", t, r / 1024, c, l }'
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$elapsed" "$rss_total" "$cpu_sample" "$life_total" "${#cur_pids[@]}" "$cpu_valid" >> "$tmp"

        if [[ "$breakdown" == "1" ]]; then
            for i in "${!cur_pids[@]}"; do
                awk -v p="${cur_pids[$i]}" -v r="${cur_rss[$i]}" \
                    -v c="${cur_sample[$i]}" -v l="${cur_life[$i]}" -v n="${cur_comm[$i]}" \
                    'BEGIN { printf "           pid %7d  %6.1f MB  sample %6.2f%%  lifetime %6.2f%%  %s\n", p, r / 1024, c, l, n }'
            done
        fi
    fi

    prev_ts="$ts"
    prev_pids=("${cur_pids[@]}")
    prev_secs=()
    for i in "${!cur_pids[@]}"; do
        prev_secs+=("${sec_by_pid[${cur_pids[$i]}]-}")
    done

    sleep "$interval"
    elapsed=$(( elapsed + interval ))
done

awk -F, '
    NR == 0 { print "No samples collected."; exit }
    {
        n++
        rss_sum += $2; if ($2 > rss_max) rss_max = $2
        life_sum += $4
        procs_sum += $5
        if ($5 > procs_max) procs_max = $5
        if (procs_min == 0 || $5 < procs_min) procs_min = $5
        if ($6 == 1) { cpu_n++; cpu_sum += $3; if ($3 > cpu_max) cpu_max = $3 }
    }
    END {
        if (n == 0) { print "No samples collected."; exit }
        printf "\nSamples: %d (CPU averaged over %d)\n", n, cpu_n
        printf "Processes: min %d, avg %.1f, max %d\n", procs_min, procs_sum / n, procs_max
        printf "RSS:     avg %.1f MB, max %.1f MB  (budget < 50 MB)\n", rss_sum / n / 1024, rss_max / 1024
        printf "CPU:     avg %.2f%%, sampled max %.2f%%  (budget < 3%% average)\n", (cpu_n ? cpu_sum / cpu_n : 0), cpu_max
        printf "CPU:     lifetime avg %.2f%% (ps, includes launch/setup)\n", life_sum / n
    }
' "$tmp"
