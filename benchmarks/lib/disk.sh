#!/usr/bin/env bash
set -euo pipefail

##
# disk.sh — Disk I/O benchmark driver (fio)
#
# Usage:
#   disk.sh <iterations> [runtime_secs] [warmup]
#
# Arguments:
#   iterations    Number of measured runs
#   runtime_secs  How long each fio sub-test runs per iteration (default: 5)
#   warmup        "true" or "false" — run one throwaway iteration first (default: true)
#
# Runs 4 sub-tests per iteration:
#   1. Sequential read  (MB/s)
#   2. Sequential write (MB/s)
#   3. Random read      (IOPS)
#   4. Random write     (IOPS)
#
# Computes a composite score as the geometric mean of all 4 sub-test scores.
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: disk.sh <iterations> [runtime_secs] [warmup]" >&2
  exit 1
fi

iterations="$1"
runtime="${2:-5}"
warmup="${3:-true}"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: iterations must be a positive integer, got '${iterations}'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in fio jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Platform-specific flags
# ---------------------------------------------------------------------------
direct_flag="--direct=1"
if [[ "$(uname)" == "Darwin" ]]; then
  direct_flag="--direct=0"
fi

# ---------------------------------------------------------------------------
# Temp directory for fio test files
# ---------------------------------------------------------------------------
FIO_DIR="/tmp/fio-bench"
mkdir -p "$FIO_DIR"
trap 'rm -rf "$FIO_DIR"' EXIT

# ---------------------------------------------------------------------------
# Helper: run one full iteration (4 sub-tests), print 4 values to stdout
#   seq_read (MB/s)  seq_write (MB/s)  rand_read (IOPS)  rand_write (IOPS)
# ---------------------------------------------------------------------------
run_once() {
  local output val

  # 1. Sequential read — bandwidth in MB/s
  output=$(fio --name=seq_read --rw=read --bs=1M --size=256M --numjobs=1 \
    --ioengine=psync --runtime="$runtime" --time_based \
    --directory="$FIO_DIR" --output-format=json --thread $direct_flag)
  val=$(echo "$output" | jq '.jobs[0].read.bw')
  local seq_read
  seq_read=$(awk "BEGIN { printf \"%.2f\", $val / 1024 }")

  # 2. Sequential write — bandwidth in MB/s
  output=$(fio --name=seq_write --rw=write --bs=1M --size=256M --numjobs=1 \
    --ioengine=psync --runtime="$runtime" --time_based \
    --directory="$FIO_DIR" --output-format=json --thread $direct_flag)
  val=$(echo "$output" | jq '.jobs[0].write.bw')
  local seq_write
  seq_write=$(awk "BEGIN { printf \"%.2f\", $val / 1024 }")

  # 3. Random read — IOPS
  output=$(fio --name=rand_read --rw=randread --bs=4K --size=64M --numjobs=1 \
    --ioengine=psync --runtime="$runtime" --time_based \
    --directory="$FIO_DIR" --output-format=json --thread $direct_flag)
  local rand_read
  rand_read=$(echo "$output" | jq -r '.jobs[0].read.iops' | awk '{ printf "%.2f", $1 }')

  # 4. Random write — IOPS
  output=$(fio --name=rand_write --rw=randwrite --bs=4K --size=64M --numjobs=1 \
    --ioengine=psync --runtime="$runtime" --time_based \
    --directory="$FIO_DIR" --output-format=json --thread $direct_flag)
  local rand_write
  rand_write=$(echo "$output" | jq -r '.jobs[0].write.iops' | awk '{ printf "%.2f", $1 }')

  echo "$seq_read $seq_write $rand_read $rand_write"
}

# ---------------------------------------------------------------------------
# Helper: compute stats for a single metric array
#   calc_stats "val1 val2 val3 ..." → prints: median min max stddev
# ---------------------------------------------------------------------------
calc_stats() {
  local values_str="$1"
  local sorted
  sorted=($(printf '%s\n' $values_str | sort -g))
  local count=${#sorted[@]}

  # median
  local median
  if (( count % 2 == 1 )); then
    local mid=$(( count / 2 ))
    median="${sorted[$mid]}"
  else
    local mid_upper=$(( count / 2 ))
    local mid_lower=$(( mid_upper - 1 ))
    median=$(awk "BEGIN { printf \"%.2f\", (${sorted[$mid_lower]} + ${sorted[$mid_upper]}) / 2 }")
  fi

  # min, max
  local min_score="${sorted[0]}"
  local max_score="${sorted[$((count - 1))]}"

  # stddev = sqrt( sum((x - mean)^2) / N )
  local stddev
  stddev=$(printf '%s\n' $values_str | awk '{
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

  echo "$median $min_score $max_score $stddev"
}

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
if [[ "$warmup" == "true" ]]; then
  echo "Warmup: running one throwaway iteration..." >&2
  run_once >/dev/null
fi

# ---------------------------------------------------------------------------
# Measured runs
# ---------------------------------------------------------------------------
all_seq_read=()
all_seq_write=()
all_rand_read=()
all_rand_write=()
all_composite=()

for ((i = 1; i <= iterations; i++)); do
  echo "Running disk benchmark (iteration ${i}/${iterations})..." >&2
  result=$(run_once)
  read -r sr sw rr rw <<< "$result"

  all_seq_read+=("$sr")
  all_seq_write+=("$sw")
  all_rand_read+=("$rr")
  all_rand_write+=("$rw")

  # Composite = geometric mean of all 4 values
  composite=$(awk "BEGIN { printf \"%.2f\", ($sr * $sw * $rr * $rw) ^ 0.25 }")
  all_composite+=("$composite")

  echo "  seq_read: ${sr} MB/s" >&2
  echo "  seq_write: ${sw} MB/s" >&2
  echo "  rand_read: ${rr} IOPS" >&2
  echo "  rand_write: ${rw} IOPS" >&2
  echo "  composite: ${composite}" >&2
done

# ---------------------------------------------------------------------------
# Calculate statistics for each metric
# ---------------------------------------------------------------------------
read -r comp_median comp_min comp_max comp_stddev <<< "$(calc_stats "${all_composite[*]}")"
read -r sr_median sr_min sr_max sr_stddev <<< "$(calc_stats "${all_seq_read[*]}")"
read -r sw_median sw_min sw_max sw_stddev <<< "$(calc_stats "${all_seq_write[*]}")"
read -r rr_median rr_min rr_max rr_stddev <<< "$(calc_stats "${all_rand_read[*]}")"
read -r rw_median rw_min rw_max rw_stddev <<< "$(calc_stats "${all_rand_write[*]}")"

# ---------------------------------------------------------------------------
# Build JSON output
# ---------------------------------------------------------------------------
comp_scores_json=$(printf '%s\n' "${all_composite[@]}" | jq -s '.')
sr_scores_json=$(printf '%s\n' "${all_seq_read[@]}" | jq -s '.')
sw_scores_json=$(printf '%s\n' "${all_seq_write[@]}" | jq -s '.')
rr_scores_json=$(printf '%s\n' "${all_rand_read[@]}" | jq -s '.')
rw_scores_json=$(printf '%s\n' "${all_rand_write[@]}" | jq -s '.')

jq -n \
  --arg tool              "fio" \
  --argjson iters         "$iterations" \
  --argjson runtime_secs  "$runtime" \
  --argjson comp_scores   "$comp_scores_json" \
  --argjson comp_median   "$comp_median" \
  --argjson comp_min      "$comp_min" \
  --argjson comp_max      "$comp_max" \
  --argjson comp_stddev   "$comp_stddev" \
  --argjson sr_scores     "$sr_scores_json" \
  --argjson sr_median     "$sr_median" \
  --argjson sr_min        "$sr_min" \
  --argjson sr_max        "$sr_max" \
  --argjson sr_stddev     "$sr_stddev" \
  --argjson sw_scores     "$sw_scores_json" \
  --argjson sw_median     "$sw_median" \
  --argjson sw_min        "$sw_min" \
  --argjson sw_max        "$sw_max" \
  --argjson sw_stddev     "$sw_stddev" \
  --argjson rr_scores     "$rr_scores_json" \
  --argjson rr_median     "$rr_median" \
  --argjson rr_min        "$rr_min" \
  --argjson rr_max        "$rr_max" \
  --argjson rr_stddev     "$rr_stddev" \
  --argjson rw_scores     "$rw_scores_json" \
  --argjson rw_median     "$rw_median" \
  --argjson rw_min        "$rw_min" \
  --argjson rw_max        "$rw_max" \
  --argjson rw_stddev     "$rw_stddev" \
  '{
    tool:              $tool,
    iterations:        $iters,
    runtime_seconds:   $runtime_secs,
    composite: {
      scores: $comp_scores,
      median: $comp_median,
      min:    $comp_min,
      max:    $comp_max,
      stddev: $comp_stddev,
      unit:   "score"
    },
    seq_read: {
      scores: $sr_scores,
      median: $sr_median,
      min:    $sr_min,
      max:    $sr_max,
      stddev: $sr_stddev,
      unit:   "MB/s"
    },
    seq_write: {
      scores: $sw_scores,
      median: $sw_median,
      min:    $sw_min,
      max:    $sw_max,
      stddev: $sw_stddev,
      unit:   "MB/s"
    },
    rand_read: {
      scores: $rr_scores,
      median: $rr_median,
      min:    $rr_min,
      max:    $rr_max,
      stddev: $rr_stddev,
      unit:   "IOPS"
    },
    rand_write: {
      scores: $rw_scores,
      median: $rw_median,
      min:    $rw_min,
      max:    $rw_max,
      stddev: $rw_stddev,
      unit:   "IOPS"
    }
  }'
