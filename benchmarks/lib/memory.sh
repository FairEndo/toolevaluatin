#!/usr/bin/env bash
set -euo pipefail

##
# memory.sh — Memory benchmark driver (sysbench)
#
# Usage:
#   memory.sh <iterations> [memory_block_size] [memory_total_size] [warmup]
#
# Arguments:
#   iterations        Number of measured runs
#   memory_block_size  Block size for memory operations (default: 1K)
#   memory_total_size  Total size of data to transfer (default: 10G)
#   warmup             "true" or "false" — run one throwaway iteration first (default: true)
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: memory.sh <iterations> [memory_block_size] [memory_total_size] [warmup]" >&2
  exit 1
fi

iterations="$1"
memory_block_size="${2:-1K}"
memory_total_size="${3:-10G}"
warmup="${4:-true}"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: iterations must be a positive integer, got '${iterations}'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in sysbench jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helper: run sysbench once, print MiB/sec to stdout
# ---------------------------------------------------------------------------
run_once() {
  local output
  output=$(sysbench memory --memory-block-size="$memory_block_size" --memory-total-size="$memory_total_size" --threads=1 run)
  local throughput
  throughput=$(echo "$output" | grep -i 'MiB/sec' | grep -oE '\([0-9]+\.?[0-9]* MiB/sec\)' | grep -oE '[0-9]+\.?[0-9]*')
  if [[ -z "$throughput" ]]; then
    echo "Error: failed to parse 'MiB/sec' from sysbench output" >&2
    echo "--- begin sysbench output ---" >&2
    echo "$output" >&2
    echo "--- end sysbench output ---" >&2
    return 1
  fi
  echo "$throughput"
}

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
if [[ "$warmup" == "true" ]]; then
  echo "Warmup: running one throwaway iteration..." >&2
  warmup_score=$(run_once)
  echo "  -> ${warmup_score} MiB/sec (discarded)" >&2
fi

# ---------------------------------------------------------------------------
# Measured runs
# ---------------------------------------------------------------------------
scores=()

for ((i = 1; i <= iterations; i++)); do
  echo "Running memory benchmark (iteration ${i}/${iterations})..." >&2
  throughput=$(run_once)
  scores+=("$throughput")
  echo "  -> ${throughput} MiB/sec" >&2
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
  --arg tool        "sysbench" \
  --argjson iters   "$iterations" \
  --argjson scores  "$scores_json" \
  --argjson median  "$median" \
  --argjson min     "$min_score" \
  --argjson max     "$max_score" \
  --argjson stddev  "$stddev" \
  --arg unit        "MiB/sec" \
  '{
    tool:       $tool,
    iterations: $iters,
    scores:     $scores,
    median:     $median,
    min:        $min,
    max:        $max,
    stddev:     $stddev,
    unit:       $unit
  }'
