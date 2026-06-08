#!/bin/bash
#
# Measure peak memory of a command and its entire process tree (macOS/Linux).
#
# Spawns the given command, then samples the resident memory of the launched
# process AND all of its descendants on a fixed interval, summing across the
# tree. Reports the peak and writes a timestamped time series (CSV) so you can
# see *when* the peak occurred (e.g. the shutdown-persist spike of `next build`).
#
# This is bundler/command agnostic — point it at anything:
#
#   scripts/measure-rss.sh next build
#   scripts/measure-rss.sh -- pnpm --filter=next build
#   scripts/measure-rss.sh -i 50 -o /tmp/run.csv -- node script.js
#
# Why tree-aware: `next build` forks worker processes (the turbo-tasks backend
# runs there), so the meaningful peak is the SUM of RSS across the whole tree
# sampled over time — `/usr/bin/time -l` only reports the root process.
#
# Why "footprint" mode: on macOS, RSS overcounts shared pages. `--footprint`
# samples phys_footprint (the OS's real per-process accounting, via the
# `footprint` tool) instead. It is slower, so it samples less aggressively and
# is opt-in; default RSS sampling is cheap enough for 100ms intervals.
#
# Usage:
#   scripts/measure-rss.sh [options] [--] <command> [args...]
#
# Options:
#   -i, --interval-ms N   Sample interval in milliseconds (default: 100)
#   -o, --output FILE     CSV output path (default: /tmp/measure-rss-<pid>.csv)
#   -f, --footprint       Use macOS phys_footprint (slower, truer). Implies a
#                         minimum 250ms interval. macOS only.
#   -q, --quiet           Don't echo the command's stdout/stderr (still timed).
#   -h, --help            Show this help.
#
# Output:
#   - A CSV with columns: elapsed_s,tree_kb,nprocs
#   - A summary line with peak (in MB) and when it occurred.
#   - The wrapped command's own exit code is propagated.

set -uo pipefail

INTERVAL_MS=100
OUTPUT=""
USE_FOOTPRINT=0
QUIET=0

print_help() {
  sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'
}

# --- parse options (stop at -- or first non-option) ---
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--interval-ms) INTERVAL_MS="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -f|--footprint) USE_FOOTPRINT=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "error: no command given" >&2
  print_help >&2
  exit 2
fi

OS="$(uname -s)"
if [ "$USE_FOOTPRINT" = 1 ]; then
  if [ "$OS" != "Darwin" ]; then
    echo "error: --footprint is macOS only" >&2
    exit 2
  fi
  if [ "$INTERVAL_MS" -lt 250 ]; then
    INTERVAL_MS=250
  fi
fi

if [ -z "$OUTPUT" ]; then
  OUTPUT="/tmp/measure-rss-$$.csv"
fi

# Sleep duration in (fractional) seconds for the sampler loop.
INTERVAL_S=$(awk "BEGIN { printf \"%.3f\", $INTERVAL_MS / 1000 }")

# --- launch the command in its own process group so we can find descendants ---
if [ "$QUIET" = 1 ]; then
  "$@" >/dev/null 2>&1 &
else
  "$@" &
fi
CMD_PID=$!

echo "measuring: $* (pid $CMD_PID)" >&2
echo "interval: ${INTERVAL_MS}ms  mode: $([ "$USE_FOOTPRINT" = 1 ] && echo phys_footprint || echo rss)  csv: $OUTPUT" >&2

echo "elapsed_s,tree_kb,nprocs" > "$OUTPUT"

# Collect the descendant PID set of a root pid using the ppid table.
# Echoes the root plus all transitive children, one per line.
collect_tree() {
  local root="$1"
  # ppid_map: lines of "pid ppid"
  local ppid_map
  ppid_map="$(ps -axo pid=,ppid= 2>/dev/null)"
  # BFS over the ppid table.
  awk -v root="$root" '
    { child[$2] = child[$2] " " $1 }   # child[ppid] += pid
    END {
      n = 0; queue[n++] = root
      for (i = 0; i < n; i++) {
        p = queue[i]
        print p
        split(child[p], kids, " ")
        for (k in kids) if (kids[k] != "") queue[n++] = kids[k]
      }
    }
  ' <<< "$ppid_map"
}

PEAK_KB=0
PEAK_AT="0"
START_NS=$(date +%s%N 2>/dev/null || echo "")
# macOS `date` lacks %N; fall back to SECONDS-based timing.
have_ns=1
if [ -z "$START_NS" ] || [ "$START_NS" = "$(date +%s)N" ]; then
  have_ns=0
fi
SECONDS=0

while kill -0 "$CMD_PID" 2>/dev/null; do
  # Build the current tree PID list.
  pids="$(collect_tree "$CMD_PID")"
  pid_csv="$(echo "$pids" | tr '\n' ',' | sed 's/,$//')"

  tree_kb=0
  nprocs=0
  if [ -n "$pid_csv" ]; then
    if [ "$USE_FOOTPRINT" = 1 ]; then
      # phys_footprint via `footprint`, summed across the tree.
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        kb=$(footprint -p "$p" 2>/dev/null \
              | awk '/phys_footprint/ { gsub(/[^0-9.]/,"",$0) } /Physical footprint:/ { print }' )
        # `footprint` summary format varies; fall back to ps rss if it failed.
        if [ -z "$kb" ]; then
          kb=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ')
        fi
        [ -n "$kb" ] && tree_kb=$((tree_kb + kb))
        nprocs=$((nprocs + 1))
      done <<< "$pids"
    else
      # Fast path: one `ps` call over the whole pid set, sum the rss column (KB).
      read -r tree_kb nprocs < <(
        ps -o rss= -p "$pid_csv" 2>/dev/null \
          | awk '{ s += $1; n += 1 } END { printf "%d %d", s, n }'
      )
      tree_kb=${tree_kb:-0}
      nprocs=${nprocs:-0}
    fi
  fi

  if [ "$have_ns" = 1 ]; then
    now_ns=$(date +%s%N)
    elapsed=$(awk "BEGIN { printf \"%.3f\", ($now_ns - $START_NS) / 1000000000 }")
  else
    elapsed="$SECONDS"
  fi

  echo "$elapsed,$tree_kb,$nprocs" >> "$OUTPUT"

  if [ "$tree_kb" -gt "$PEAK_KB" ]; then
    PEAK_KB=$tree_kb
    PEAK_AT=$elapsed
  fi

  sleep "$INTERVAL_S"
done

wait "$CMD_PID"
EXIT_CODE=$?

PEAK_MB=$(awk "BEGIN { printf \"%.1f\", $PEAK_KB / 1024 }")
echo "" >&2
echo "=== peak tree $([ "$USE_FOOTPRINT" = 1 ] && echo phys_footprint || echo RSS): ${PEAK_MB} MB at t=${PEAK_AT}s ===" >&2
echo "csv: $OUTPUT  (cols: elapsed_s,tree_kb,nprocs)" >&2
echo "command exit code: $EXIT_CODE" >&2

exit "$EXIT_CODE"
