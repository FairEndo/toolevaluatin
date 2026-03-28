#!/usr/bin/env bash
set -euo pipefail

##
# cpu.sh — CPU benchmark driver (sysbench)
#
# Usage:
#   cpu.sh <iterations> [cpu_max_prime]
#
# Arguments:
#   iterations     Number of measured runs
#   cpu_max_prime  Upper limit for prime-number generation (default: 20000)
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: cpu.sh <iterations> [cpu_max_prime]" >&2
  exit 1
fi

iterations="$1"
cpu_max_prime="${2:-20000}"

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
# Helper: run sysbench once, print events/sec to stdout
# ---------------------------------------------------------------------------
run_once() {
  local output
  output=$(sysbench cpu --cpu-max-prime="$cpu_max_prime" --threads=1 run)
  local eps
  eps=$(echo "$output" | grep -i 'events per second' | awk -F':' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
  if [[ -z "$eps" ]]; then
    echo "Error: failed to parse 'events per second' from sysbench output" >&2
    echo "--- begin sysbench output ---" >&2
    echo "$output" >&2
    echo "--- end sysbench output ---" >&2
    return 1
  fi
  echo "$eps"
}

# ---------------------------------------------------------------------------
# Measured runs
# ---------------------------------------------------------------------------
scores=()

for ((i = 1; i <= iterations; i++)); do
  echo "Running CPU benchmark (iteration ${i}/${iterations})..." >&2
  eps=$(run_once)
  scores+=("$eps")
  echo "  -> ${eps} events/sec" >&2
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
  --arg unit        "events/sec" \
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
