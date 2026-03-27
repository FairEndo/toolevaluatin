#!/usr/bin/env bash
set -euo pipefail

##
# compile.sh — Compilation benchmark driver (Redis build)
#
# Usage:
#   compile.sh <iterations>
#
# Arguments:
#   iterations  Number of measured builds
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REDIS_VERSION="7.2.7"
REDIS_URL="https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: compile.sh <iterations>" >&2
  exit 1
fi

iterations="$1"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: iterations must be a positive integer, got '${iterations}'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in curl make jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

# Check for a C compiler
CC=""
for candidate in gcc cc clang; do
  if command -v "$candidate" &>/dev/null; then
    CC="$candidate"
    break
  fi
done

if [[ -z "$CC" ]]; then
  echo "Error: no C compiler found (tried gcc, cc, clang)" >&2
  exit 1
fi

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

JOBS=$(get_cores)
JOBS=${JOBS:-1}

# ---------------------------------------------------------------------------
# Timing helper (millisecond precision)
# ---------------------------------------------------------------------------
get_time() {
  python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

TARBALL="$WORK_DIR/redis.tar.gz"
BUILD_DIR="$WORK_DIR/redis-${REDIS_VERSION}"

echo "Downloading Redis ${REDIS_VERSION}..." >&2
if ! curl -fsSL "$REDIS_URL" -o "$TARBALL"; then
  echo "Error: failed to download Redis tarball from ${REDIS_URL}" >&2
  exit 1
fi

echo "Using ${JOBS} parallel job(s)" >&2

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
echo "Warmup: building Redis once (discarded)..." >&2
tar xzf "$TARBALL" -C "$WORK_DIR"
make -j"$JOBS" -C "$BUILD_DIR" > /dev/null 2>&1
echo "  -> warmup complete" >&2

# ---------------------------------------------------------------------------
# Measured runs
# ---------------------------------------------------------------------------
scores=()

for ((i = 1; i <= iterations; i++)); do
  echo "Running compile benchmark (iteration ${i}/${iterations})..." >&2
  rm -rf "$BUILD_DIR"
  tar xzf "$TARBALL" -C "$WORK_DIR"
  START=$(get_time)
  make -j"$JOBS" -C "$BUILD_DIR" > /dev/null 2>&1
  END=$(get_time)
  score=$(awk "BEGIN {printf \"%.2f\", $END - $START}")
  scores+=("$score")
  echo "  -> ${score} seconds" >&2
done

# ---------------------------------------------------------------------------
# Calculate median
# ---------------------------------------------------------------------------
sorted=($(printf '%s\n' "${scores[@]}" | sort -g))
count=${#sorted[@]}

if (( count % 2 == 1 )); then
  mid=$(( count / 2 ))
  median="${sorted[$mid]}"
else
  mid_upper=$(( count / 2 ))
  mid_lower=$(( mid_upper - 1 ))
  median=$(awk "BEGIN { printf \"%.2f\", (${sorted[$mid_lower]} + ${sorted[$mid_upper]}) / 2 }")
fi

# ---------------------------------------------------------------------------
# Calculate min, max, standard deviation
# ---------------------------------------------------------------------------
min_score="${sorted[0]}"
max_score="${sorted[$((count - 1))]}"

# stddev = sqrt( sum((x - mean)^2) / N )
stddev=$(printf '%s\n' "${scores[@]}" | awk '{
  sum += $1; sumsq += ($1 * $1); n++
} END {
  if (n > 0) {
    mean = sum / n
    variance = (sumsq / n) - (mean * mean)
    if (variance < 0) variance = 0
    printf "%.2f", sqrt(variance)
  } else {
    printf "0"
  }
}')

# ---------------------------------------------------------------------------
# Build JSON output
# ---------------------------------------------------------------------------
scores_json=$(printf '%s\n' "${scores[@]}" | jq -s '.')

jq -n \
  --arg tool            "make" \
  --arg project         "redis" \
  --arg project_version "$REDIS_VERSION" \
  --argjson iters       "$iterations" \
  --argjson jobs        "$JOBS" \
  --argjson scores      "$scores_json" \
  --argjson median      "$median" \
  --argjson min         "$min_score" \
  --argjson max         "$max_score" \
  --argjson stddev      "$stddev" \
  --arg unit            "seconds" \
  '{
    tool:            $tool,
    project:         $project,
    project_version: $project_version,
    iterations:      $iters,
    parallel_jobs:   $jobs,
    scores:          $scores,
    median:          $median,
    min:             $min,
    max:             $max,
    stddev:          $stddev,
    unit:            $unit
  }'
