#!/usr/bin/env bash
set -euo pipefail

##
# threading.sh — Multi-thread scaling benchmark (hyperfine + sysbench)
#
# Measures how well a runner scales across thread counts by running
# sysbench CPU at increasing thread counts (powers of 2 up to max vCPUs)
# and recording wall-clock time via hyperfine.
#
# The key metric is the "scaling factor": single-threaded time divided by
# max-threaded time.  A perfect scaling factor equals the thread count.
#
# Usage:
#   threading.sh <runs> [warmup] [cpu_max_prime]
#
# Arguments:
#   runs           Number of timed runs per thread count (hyperfine --runs)
#   warmup         Number of warmup runs per thread count (default: 1)
#   cpu_max_prime  Upper limit for prime-number generation (default: 20000)
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: threading.sh <runs> [warmup] [cpu_max_prime]" >&2
  exit 1
fi

runs="$1"
warmup="${2:-1}"
cpu_max_prime="${3:-20000}"

if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: runs must be a positive integer, got '${runs}'" >&2
  exit 1
fi

if ! [[ "$warmup" =~ ^[0-9]+$ ]]; then
  echo "Error: warmup must be a non-negative integer, got '${warmup}'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in hyperfine sysbench jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Core detection (cgroups-aware)
# ---------------------------------------------------------------------------
get_cores() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sysctl -n hw.ncpu 2>/dev/null || echo 1
    return
  fi
  # cgroups v2 (Ubuntu 22.04+, modern Docker)
  if [[ -f /sys/fs/cgroup/cpu.max ]]; then
    local quota period
    read -r quota period < /sys/fs/cgroup/cpu.max
    if [[ "$quota" != "max" && "$quota" -gt 0 ]]; then
      echo $(( quota / period ))
      return
    fi
  fi
  # cgroups v1
  if [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
    local quota period
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [[ "$quota" -gt 0 ]]; then
      echo $(( quota / period ))
      return
    fi
  fi
  # Fallback
  nproc 2>/dev/null || echo 1
}

MAX_THREADS=$(get_cores)
MAX_THREADS=${MAX_THREADS:-1}

# Ensure at least 2 threads for a meaningful scaling test
if [[ "$MAX_THREADS" -lt 2 ]]; then
  echo "Warning: only ${MAX_THREADS} vCPU detected — scaling test needs at least 2, using 2" >&2
  MAX_THREADS=2
fi

# ---------------------------------------------------------------------------
# Build thread count list (powers of 2 up to max, always including 1 and max)
# ---------------------------------------------------------------------------
build_thread_list() {
  local max=$1
  local -a threads=(1)
  local t=2
  while (( t < max )); do
    threads+=("$t")
    t=$(( t * 2 ))
  done
  threads+=("$max")
  # Deduplicate, sort numerically, join with commas
  printf '%s\n' "${threads[@]}" | sort -un | paste -sd ',' -
}

THREAD_LIST=$(build_thread_list "$MAX_THREADS")

echo "Multi-thread scaling benchmark (hyperfine + sysbench)" >&2
echo "  Max vCPUs:            ${MAX_THREADS}" >&2
echo "  Thread counts:        ${THREAD_LIST}" >&2
echo "  Runs per thread count: ${runs}" >&2
echo "  Warmup runs:          ${warmup}" >&2
echo "  CPU max prime:        ${cpu_max_prime}" >&2

# ---------------------------------------------------------------------------
# Run hyperfine
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "Running hyperfine..." >&2

hyperfine \
  --warmup "$warmup" \
  --runs "$runs" \
  --parameter-list t "$THREAD_LIST" \
  --export-json "$TMPFILE" \
  --style basic \
  "sysbench cpu --cpu-max-prime=${cpu_max_prime} --threads={t} run" \
  >&2

echo "Hyperfine complete — parsing results..." >&2

# ---------------------------------------------------------------------------
# Parse hyperfine JSON and build output
# ---------------------------------------------------------------------------
# hyperfine's JSON structure:
#   { "results": [ { "command": "...", "mean": N, "stddev": N, "median": N,
#                     "min": N, "max": N, "times": [...],
#                     "parameters": { "t": "1" } }, ... ] }

jq -n \
  --arg tool            "hyperfine" \
  --arg workload        "sysbench-cpu" \
  --argjson cpu_max_prime "$cpu_max_prime" \
  --argjson max_threads "$MAX_THREADS" \
  --argjson warmup      "$warmup" \
  --argjson runs        "$runs" \
  --slurpfile hf        "$TMPFILE" \
  '
    # Extract and reshape per-thread-count results
    ($hf[0].results | map({
      threads:  (.parameters.t | tonumber),
      mean:     ((.mean * 1000 | round) / 1000),
      stddev:   ((.stddev * 1000 | round) / 1000),
      median:   ((.median * 1000 | round) / 1000),
      min:      ((.min * 1000 | round) / 1000),
      max:      ((.max * 1000 | round) / 1000)
    }) | sort_by(.threads)) as $results |

    # Single-threaded mean time
    ($results | map(select(.threads == 1)) | .[0].mean) as $t1_mean |

    # Max-threaded mean time
    ($results | last.mean) as $tmax_mean |

    # Scaling factor: how many times faster is max-threads vs 1-thread
    (if $tmax_mean > 0 then
      (($t1_mean / $tmax_mean * 100) | round) / 100
    else 0 end) as $scaling |

    {
      tool:            $tool,
      workload:        $workload,
      cpu_max_prime:   $cpu_max_prime,
      max_threads:     $max_threads,
      warmup:          $warmup,
      runs:            $runs,
      results:         $results,
      scaling_factor:  $scaling,
      unit:            "seconds"
    }
  '
