#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# benchmarks/run.sh — Main entrypoint for CI benchmark runs
#
# Called by all CI configs (GitHub Actions, CircleCI, etc.).
# Reads flat key-value config from config/benchmarks.yml, collects system info,
# runs enabled benchmarks, writes JSON results, and regenerates the summary.
#
# Environment variable overrides (take precedence over config file):
#   CI_BENCH_PROVIDER            — provider name (e.g. "github-actions")
#   CI_BENCH_RUNNER              — runner label (e.g. "ubuntu-latest")
#   CI_BENCH_CPU_ENABLED         — "true" / "false"
#   CI_BENCH_ITERATIONS          — number of measured iterations
#   CI_BENCH_CPU_MAX_PRIME       — sysbench cpu-max-prime parameter
#   CI_BENCH_CPU_WARMUP          — "true" / "false"
#   CI_BENCH_MEMORY_ENABLED      — "true" / "false"
#   CI_BENCH_MEMORY_ITERATIONS   — number of measured iterations (memory)
#   CI_BENCH_MEMORY_BLOCK_SIZE   — sysbench memory-block-size parameter
#   CI_BENCH_MEMORY_TOTAL_SIZE   — sysbench memory-total-size parameter
#   CI_BENCH_MEMORY_WARMUP       — "true" / "false"
#   CI_BENCH_RESULTS_DIR             — path to external results repository root
###############################################################################

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/benchmarks.yml"
LIB_DIR="${SCRIPT_DIR}/lib"

OVERALL_START=$(date +%s)

# ---------------------------------------------------------------------------
# Queue / startup timing
# ---------------------------------------------------------------------------
# CI_BENCH_TRIGGER_TIME    — when the pipeline was created (from CI provider)
# CI_BENCH_JOB_STARTED_AT  — when the runner picked up the job (first CI step)
# OVERALL_START             — when this script began (benchmark start)

TRIGGER_TIME="${CI_BENCH_TRIGGER_TIME:-}"
JOB_STARTED_AT="${CI_BENCH_JOB_STARTED_AT:-}"
BENCH_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Cross-platform ISO 8601 → epoch converter
iso_to_epoch() {
    local ts="$1"
    if date -d "$ts" +%s 2>/dev/null; then
        return
    fi
    # macOS: try -jf with fractional seconds, then without
    date -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
        || date -jf "%Y-%m-%dT%H:%M:%SZ" "${ts%Z}" +%s 2>/dev/null \
        || echo ""
}

QUEUE_SECONDS="null"
SETUP_SECONDS="null"
TOTAL_QUEUE_SETUP_SECONDS="null"

if [[ -n "$TRIGGER_TIME" && -n "$JOB_STARTED_AT" ]]; then
    trigger_epoch=$(iso_to_epoch "$TRIGGER_TIME")
    job_epoch=$(iso_to_epoch "$JOB_STARTED_AT")
    bench_epoch="$OVERALL_START"
    if [[ -n "$trigger_epoch" && -n "$job_epoch" ]]; then
        QUEUE_SECONDS=$(( job_epoch - trigger_epoch ))
        SETUP_SECONDS=$(( bench_epoch - job_epoch ))
        TOTAL_QUEUE_SETUP_SECONDS=$(( bench_epoch - trigger_epoch ))
        # Guard against negative values from clock skew
        [[ "$QUEUE_SECONDS" -lt 0 ]] && QUEUE_SECONDS=0
        [[ "$SETUP_SECONDS" -lt 0 ]] && SETUP_SECONDS=0
        [[ "$TOTAL_QUEUE_SETUP_SECONDS" -lt 0 ]] && TOTAL_QUEUE_SETUP_SECONDS=0
    fi
fi

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------
log() { printf '[bench] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }

# Debug mode: when CI_BENCH_DEBUG=true, emit extra diagnostic output
CI_BENCH_DEBUG="${CI_BENCH_DEBUG:-false}"

debug_log() {
  if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
    log "[DEBUG] $*"
  fi
}

# Timer helpers for tracking step durations
timer_start() { date +%s; }
timer_elapsed() {
  local start="$1"
  local end
  end=$(date +%s)
  echo $(( end - start ))
}

# Results can live outside the benchmarking repo via CI_BENCH_RESULTS_DIR
if [[ -n "${CI_BENCH_RESULTS_DIR:-}" ]]; then
    RESULTS_BASE="$(cd "${CI_BENCH_RESULTS_DIR}" && pwd)"
    log "Using external results directory: ${RESULTS_BASE}"
else
    RESULTS_BASE="${PROJECT_ROOT}"
fi
RESULTS_DIR="${RESULTS_BASE}/results"
RAW_DIR="${RESULTS_DIR}/raw"

# Lightweight YAML value reader for flat "key: value" files.
# Usage: yaml_get <file> <key> [default]
# Matches lines like "some_key: some_value" (ignoring leading whitespace).
# Strips inline comments, surrounding quotes, and trailing whitespace.
yaml_get() {
    local file="$1" key="$2" default="${3:-}"
    local value
    value=$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$file" 2>/dev/null \
        | head -n1 \
        | sed -E 's/^[^:]+:[[:space:]]*//' \
        | sed -E 's/[[:space:]]*#.*$//' \
        | sed -E 's/^["'"'"']//' \
        | sed -E 's/["'"'"'][[:space:]]*$//' \
        | sed -E 's/[[:space:]]+$//' \
    ) || true
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

# ---------------------------------------------------------------------------
# Parse configuration (config/benchmarks.yml) with env-var overrides
# ---------------------------------------------------------------------------
log "Reading configuration..."

if [[ -f "$CONFIG_FILE" ]]; then
    log "  Config file: ${CONFIG_FILE}"
    CFG_CPU_ENABLED="$(yaml_get  "$CONFIG_FILE" "cpu_enabled"   "true")"
    CFG_ITERATIONS="$(yaml_get   "$CONFIG_FILE" "cpu_iterations" "5")"
    CFG_CPU_MAX_PRIME="$(yaml_get "$CONFIG_FILE" "cpu_max_prime" "20000")"
    CFG_CPU_WARMUP="$(yaml_get   "$CONFIG_FILE" "cpu_warmup"    "true")"
    CFG_MEMORY_ENABLED="$(yaml_get    "$CONFIG_FILE" "memory_enabled"    "true")"
    CFG_MEMORY_ITERATIONS="$(yaml_get "$CONFIG_FILE" "memory_iterations" "5")"
    CFG_MEMORY_BLOCK_SIZE="$(yaml_get "$CONFIG_FILE" "memory_block_size" "1K")"
    CFG_MEMORY_TOTAL_SIZE="$(yaml_get "$CONFIG_FILE" "memory_total_size" "10G")"
    CFG_MEMORY_WARMUP="$(yaml_get     "$CONFIG_FILE" "memory_warmup"     "true")"
    CFG_DISK_ENABLED="$(yaml_get      "$CONFIG_FILE" "disk_enabled"      "true")"
    CFG_DISK_ITERATIONS="$(yaml_get   "$CONFIG_FILE" "disk_iterations"   "5")"
    CFG_DISK_RUNTIME="$(yaml_get      "$CONFIG_FILE" "disk_runtime"      "5")"
    CFG_DISK_WARMUP="$(yaml_get       "$CONFIG_FILE" "disk_warmup"       "true")"
else
    log "  Config file not found — using defaults"
    CFG_CPU_ENABLED="true"
    CFG_ITERATIONS="5"
    CFG_CPU_MAX_PRIME="20000"
    CFG_CPU_WARMUP="true"
    CFG_MEMORY_ENABLED="true"
    CFG_MEMORY_ITERATIONS="5"
    CFG_MEMORY_BLOCK_SIZE="1K"
    CFG_MEMORY_TOTAL_SIZE="10G"
    CFG_MEMORY_WARMUP="true"
    CFG_DISK_ENABLED="true"
    CFG_DISK_ITERATIONS="5"
    CFG_DISK_RUNTIME="5"
    CFG_DISK_WARMUP="true"
fi

# Environment variable overrides take precedence
CPU_ENABLED="${CI_BENCH_CPU_ENABLED:-$CFG_CPU_ENABLED}"
ITERATIONS="${CI_BENCH_ITERATIONS:-$CFG_ITERATIONS}"
CPU_MAX_PRIME="${CI_BENCH_CPU_MAX_PRIME:-$CFG_CPU_MAX_PRIME}"
CPU_WARMUP="${CI_BENCH_CPU_WARMUP:-$CFG_CPU_WARMUP}"
MEMORY_ENABLED="${CI_BENCH_MEMORY_ENABLED:-$CFG_MEMORY_ENABLED}"
MEMORY_ITERATIONS="${CI_BENCH_MEMORY_ITERATIONS:-$CFG_MEMORY_ITERATIONS}"
MEMORY_BLOCK_SIZE="${CI_BENCH_MEMORY_BLOCK_SIZE:-$CFG_MEMORY_BLOCK_SIZE}"
MEMORY_TOTAL_SIZE="${CI_BENCH_MEMORY_TOTAL_SIZE:-$CFG_MEMORY_TOTAL_SIZE}"
MEMORY_WARMUP="${CI_BENCH_MEMORY_WARMUP:-$CFG_MEMORY_WARMUP}"
DISK_ENABLED="${CI_BENCH_DISK_ENABLED:-$CFG_DISK_ENABLED}"
DISK_ITERATIONS="${CI_BENCH_DISK_ITERATIONS:-$CFG_DISK_ITERATIONS}"
DISK_RUNTIME="${CI_BENCH_DISK_RUNTIME:-$CFG_DISK_RUNTIME}"
DISK_WARMUP="${CI_BENCH_DISK_WARMUP:-$CFG_DISK_WARMUP}"
PROVIDER="${CI_BENCH_PROVIDER:-unknown}"
RUNNER="${CI_BENCH_RUNNER:-default}"

log "  provider           = ${PROVIDER}"
log "  runner             = ${RUNNER}"
log "  cpu_enabled        = ${CPU_ENABLED}"
log "  iterations         = ${ITERATIONS}"
log "  cpu_max_prime      = ${CPU_MAX_PRIME}"
log "  cpu_warmup         = ${CPU_WARMUP}"
log "  memory_enabled     = ${MEMORY_ENABLED}"
log "  memory_iterations  = ${MEMORY_ITERATIONS}"
log "  memory_block_size  = ${MEMORY_BLOCK_SIZE}"
log "  memory_total_size  = ${MEMORY_TOTAL_SIZE}"
log "  memory_warmup      = ${MEMORY_WARMUP}"
log "  disk_enabled       = ${DISK_ENABLED}"
log "  disk_iterations    = ${DISK_ITERATIONS}"
log "  disk_runtime       = ${DISK_RUNTIME}"
log "  disk_warmup        = ${DISK_WARMUP}"

# ---------------------------------------------------------------------------
# Collect system information
# ---------------------------------------------------------------------------
log "Collecting system information..."

# Processor model
if [[ -f /proc/cpuinfo ]]; then
    PROCESSOR="$(grep -m1 'model name' /proc/cpuinfo | sed 's/^.*: //' | xargs)" || PROCESSOR="unknown"
else
    PROCESSOR="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
fi
[[ -z "$PROCESSOR" ]] && PROCESSOR="unknown"

# vCPU count
if command -v nproc &>/dev/null; then
    VCPUS="$(nproc)"
elif command -v sysctl &>/dev/null; then
    VCPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
else
    VCPUS=1
fi

# Total RAM in MB
if command -v free &>/dev/null; then
    RAM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
elif command -v sysctl &>/dev/null; then
    RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    RAM_MB=$(( RAM_BYTES / 1024 / 1024 ))
else
    RAM_MB=0
fi

# System load (1/5/15 min averages) — helps flag noisy-neighbor runs
if command -v uptime &>/dev/null; then
    LOAD_AVG="$(uptime | sed -E 's/.*load averages?:[[:space:]]*//' | xargs)"
else
    LOAD_AVG="unknown"
fi

log "  processor = ${PROCESSOR}"
log "  vcpus     = ${VCPUS}"
log "  ram_mb    = ${RAM_MB}"
log "  load_avg  = ${LOAD_AVG}"

# OS name and version
if [[ -f /etc/os-release ]]; then
    OS_NAME="$(. /etc/os-release && echo "${NAME:-Linux}")"
    OS_VERSION="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
elif [[ "$(uname)" == "Darwin" ]]; then
    OS_NAME="macOS"
    OS_VERSION="macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
else
    OS_NAME="$(uname -s)"
    OS_VERSION="unknown"
fi

# Architecture
ARCH="$(uname -m 2>/dev/null || echo 'unknown')"

log "  os_name   = ${OS_NAME}"
log "  os_version= ${OS_VERSION}"
log "  arch      = ${ARCH}"

# ---------------------------------------------------------------------------
# Prepare output directories
# ---------------------------------------------------------------------------
mkdir -p "$RAW_DIR"

# ---------------------------------------------------------------------------
# Run enabled benchmarks
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# We accumulate benchmark JSON fragments in this object.
BENCHMARKS_JSON="{}"

# --- CPU benchmark --------------------------------------------------------
if [[ "${CPU_ENABLED}" == "true" ]]; then
    log "Running CPU benchmark..."
    CPU_START=$(timer_start)

    CPU_SCRIPT="${LIB_DIR}/cpu.sh"
    CPU_JSON=""

    if [[ -f "$CPU_SCRIPT" ]]; then
        # Delegate to the library script (call with bash to avoid executable-bit issues).
        # cpu.sh <iterations> [cpu_max_prime] [warmup]
        # Stdout = JSON result, stderr = progress messages (shown in CI logs).
        debug_log "Calling: bash $CPU_SCRIPT $ITERATIONS $CPU_MAX_PRIME $CPU_WARMUP"
        CPU_JSON="$(bash "$CPU_SCRIPT" "$ITERATIONS" "$CPU_MAX_PRIME" "$CPU_WARMUP")" || {
            log "  WARNING: cpu.sh failed — falling back to direct sysbench"
            CPU_JSON=""
        }
    fi

    # Fallback: call sysbench directly if cpu.sh is missing or failed
    if [[ -z "$CPU_JSON" ]] && command -v sysbench &>/dev/null; then
        log "  Using inline sysbench fallback..."
        CPU_SCORES=()

        # Warmup
        if [[ "$CPU_WARMUP" == "true" ]]; then
            log "  Warmup: running one throwaway iteration..."
            sysbench cpu --cpu-max-prime="$CPU_MAX_PRIME" --threads=1 run >/dev/null 2>&1 || true
        fi

        for (( i = 1; i <= ITERATIONS; i++ )); do
            log "  iteration ${i}/${ITERATIONS}"
            score="$(sysbench cpu --cpu-max-prime="$CPU_MAX_PRIME" --threads=1 run \
                | grep -i 'events per second' \
                | awk -F':' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')" || score="0"
            CPU_SCORES+=("$score")
            log "    score = ${score}"
        done

        if [[ ${#CPU_SCORES[@]} -gt 0 ]]; then
            SCORES_JSON="$(printf '%s\n' "${CPU_SCORES[@]}" | jq -s '.')"
            MEDIAN="$(printf '%s\n' "${CPU_SCORES[@]}" | jq -s 'sort | if length == 0 then 0 elif length % 2 == 1 then .[length/2 | floor] else (.[length/2 - 1] + .[length/2]) / 2 end')"
            MIN_S="$(printf '%s\n' "${CPU_SCORES[@]}" | jq -s 'min')"
            MAX_S="$(printf '%s\n' "${CPU_SCORES[@]}" | jq -s 'max')"
            STDDEV="$(printf '%s\n' "${CPU_SCORES[@]}" | awk '{sum+=$1; sumsq+=($1*$1); n++} END { if(n>0){m=sum/n; v=(sumsq/n)-(m*m); if(v<0)v=0; printf "%.2f",sqrt(v)} else print "0" }')"
            CPU_JSON="$(jq -n \
                --argjson scores "$SCORES_JSON" \
                --argjson median "$MEDIAN" \
                --argjson min "$MIN_S" \
                --argjson max "$MAX_S" \
                --argjson stddev "$STDDEV" \
                --argjson iterations "$ITERATIONS" \
                '{
                    "tool": "sysbench",
                    "iterations": $iterations,
                    "scores": $scores,
                    "median": $median,
                    "min": $min,
                    "max": $max,
                    "stddev": $stddev,
                    "unit": "events/sec"
                }'
            )"
        fi
    elif [[ -z "$CPU_JSON" ]]; then
        log "  WARNING: Neither benchmarks/lib/cpu.sh nor sysbench found — skipping CPU benchmark"
    fi

    if [[ -n "$CPU_JSON" ]]; then
        MEDIAN="$(echo "$CPU_JSON" | jq '.median')"
        STDDEV="$(echo "$CPU_JSON" | jq '.stddev')"
        log "  median = ${MEDIAN} events/sec (stddev: ${STDDEV})"
        BENCHMARKS_JSON="$(echo "$BENCHMARKS_JSON" | jq --argjson cpu "$CPU_JSON" '. + { "cpu": $cpu }')"
    fi

    CPU_ELAPSED=$(timer_elapsed "$CPU_START")
    log "  CPU benchmark completed in ${CPU_ELAPSED}s"
else
    log "CPU benchmark is disabled — skipping"
fi

# --- Memory benchmark -----------------------------------------------------
if [[ "${MEMORY_ENABLED}" == "true" ]]; then
    log "Running memory benchmark..."
    MEM_START=$(timer_start)

    MEMORY_SCRIPT="${LIB_DIR}/memory.sh"
    MEMORY_JSON=""

    if [[ -f "$MEMORY_SCRIPT" ]]; then
        # Delegate to the library script (call with bash to avoid executable-bit issues).
        # memory.sh <iterations> [memory_block_size] [memory_total_size] [warmup]
        # Stdout = JSON result, stderr = progress messages (shown in CI logs).
        debug_log "Calling: bash $MEMORY_SCRIPT $MEMORY_ITERATIONS $MEMORY_BLOCK_SIZE $MEMORY_TOTAL_SIZE $MEMORY_WARMUP"
        MEMORY_JSON="$(bash "$MEMORY_SCRIPT" "$MEMORY_ITERATIONS" "$MEMORY_BLOCK_SIZE" "$MEMORY_TOTAL_SIZE" "$MEMORY_WARMUP")" || {
            log "  WARNING: memory.sh failed — falling back to direct sysbench"
            MEMORY_JSON=""
        }
    fi

    # Fallback: call sysbench directly if memory.sh is missing or failed
    if [[ -z "$MEMORY_JSON" ]] && command -v sysbench &>/dev/null; then
        log "  Using inline sysbench fallback..."
        MEM_SCORES=()

        # Warmup
        if [[ "$MEMORY_WARMUP" == "true" ]]; then
            log "  Warmup: running one throwaway iteration..."
            sysbench memory --memory-block-size="$MEMORY_BLOCK_SIZE" --memory-total-size="$MEMORY_TOTAL_SIZE" --threads=1 run >/dev/null 2>&1 || true
        fi

        for (( i = 1; i <= MEMORY_ITERATIONS; i++ )); do
            log "  iteration ${i}/${MEMORY_ITERATIONS}"
            score="$(sysbench memory --memory-block-size="$MEMORY_BLOCK_SIZE" --memory-total-size="$MEMORY_TOTAL_SIZE" --threads=1 run \
                | grep -oE '[0-9]+\.?[0-9]*[[:space:]]*MiB/sec' \
                | grep -oE '[0-9]+\.?[0-9]*' \
                | head -n1)" || score="0"
            [[ -z "$score" ]] && score="0"
            MEM_SCORES+=("$score")
            log "    score = ${score}"
        done

        if [[ ${#MEM_SCORES[@]} -gt 0 ]]; then
            SCORES_JSON="$(printf '%s\n' "${MEM_SCORES[@]}" | jq -s '.')"
            MEDIAN="$(printf '%s\n' "${MEM_SCORES[@]}" | jq -s 'sort | if length == 0 then 0 elif length % 2 == 1 then .[length/2 | floor] else (.[length/2 - 1] + .[length/2]) / 2 end')"
            MIN_S="$(printf '%s\n' "${MEM_SCORES[@]}" | jq -s 'min')"
            MAX_S="$(printf '%s\n' "${MEM_SCORES[@]}" | jq -s 'max')"
            STDDEV="$(printf '%s\n' "${MEM_SCORES[@]}" | awk '{sum+=$1; sumsq+=($1*$1); n++} END { if(n>0){m=sum/n; v=(sumsq/n)-(m*m); if(v<0)v=0; printf "%.2f",sqrt(v)} else print "0" }')"
            MEMORY_JSON="$(jq -n \
                --argjson scores "$SCORES_JSON" \
                --argjson median "$MEDIAN" \
                --argjson min "$MIN_S" \
                --argjson max "$MAX_S" \
                --argjson stddev "$STDDEV" \
                --argjson iterations "$MEMORY_ITERATIONS" \
                '{
                    "tool": "sysbench",
                    "iterations": $iterations,
                    "scores": $scores,
                    "median": $median,
                    "min": $min,
                    "max": $max,
                    "stddev": $stddev,
                    "unit": "MiB/sec"
                }'
            )"
        fi
    elif [[ -z "$MEMORY_JSON" ]]; then
        log "  WARNING: Neither benchmarks/lib/memory.sh nor sysbench found — skipping memory benchmark"
    fi

    if [[ -n "$MEMORY_JSON" ]]; then
        MEDIAN="$(echo "$MEMORY_JSON" | jq '.median')"
        STDDEV="$(echo "$MEMORY_JSON" | jq '.stddev')"
        log "  median = ${MEDIAN} MiB/sec (stddev: ${STDDEV})"
        BENCHMARKS_JSON="$(echo "$BENCHMARKS_JSON" | jq --argjson memory "$MEMORY_JSON" '. + { "memory": $memory }')"
    fi

    MEM_ELAPSED=$(timer_elapsed "$MEM_START")
    log "  Memory benchmark completed in ${MEM_ELAPSED}s"
else
    log "Memory benchmark is disabled — skipping"
fi

# --- Disk benchmark -------------------------------------------------------
if [[ "${DISK_ENABLED}" == "true" ]]; then
    log "Running disk benchmark..."
    DISK_START=$(timer_start)

    DISK_SCRIPT="${LIB_DIR}/disk.sh"
    DISK_JSON=""

    if [[ -f "$DISK_SCRIPT" ]]; then
        # Delegate to the library script (call with bash to avoid executable-bit issues).
        # disk.sh <iterations> <runtime> <warmup>
        # Stdout = JSON result, stderr = progress messages (shown in CI logs).
        debug_log "Calling: bash $DISK_SCRIPT $DISK_ITERATIONS $DISK_RUNTIME $DISK_WARMUP"
        DISK_JSON="$(bash "$DISK_SCRIPT" "$DISK_ITERATIONS" "$DISK_RUNTIME" "$DISK_WARMUP")" || {
            log "  WARNING: disk.sh failed"
            DISK_JSON=""
        }
    else
        log "  WARNING: benchmarks/lib/disk.sh not found — skipping disk benchmark"
    fi

    if [[ -n "$DISK_JSON" ]]; then
        MEDIAN="$(echo "$DISK_JSON" | jq '.composite.median')"
        STDDEV="$(echo "$DISK_JSON" | jq '.composite.stddev')"
        log "  composite median = ${MEDIAN} (stddev: ${STDDEV})"
        BENCHMARKS_JSON="$(echo "$BENCHMARKS_JSON" | jq --argjson disk "$DISK_JSON" '. + { "disk": $disk }')"
    fi

    DISK_ELAPSED=$(timer_elapsed "$DISK_START")
    log "  Disk benchmark completed in ${DISK_ELAPSED}s"
else
    log "Disk benchmark is disabled — skipping"
fi

# ---------------------------------------------------------------------------
# Build final JSON result
# ---------------------------------------------------------------------------
log "Writing results..."

OUTPUT_FILE="${RAW_DIR}/${PROVIDER}_${RUNNER}_${TIMESTAMP//[:.]/-}.json"

jq -n \
    --arg provider   "$PROVIDER" \
    --arg runner     "$RUNNER" \
    --arg timestamp  "$TIMESTAMP" \
    --argjson benchmarks "$BENCHMARKS_JSON" \
    --arg processor  "$PROCESSOR" \
    --argjson vcpus  "$VCPUS" \
    --argjson ram_mb "$RAM_MB" \
    --arg load_avg   "$LOAD_AVG" \
    --arg os_name     "$OS_NAME" \
    --arg os_version  "$OS_VERSION" \
    --arg arch        "$ARCH" \
    --arg trigger_time      "${TRIGGER_TIME:-null}" \
    --arg job_started_at    "${JOB_STARTED_AT:-null}" \
    --arg bench_started_at  "$BENCH_STARTED_AT" \
    --argjson queue_secs    "$QUEUE_SECONDS" \
    --argjson setup_secs    "$SETUP_SECONDS" \
    --argjson total_secs    "$TOTAL_QUEUE_SETUP_SECONDS" \
    '{
        "provider":   $provider,
        "runner":     $runner,
        "timestamp":  $timestamp,
        "benchmarks": $benchmarks,
        "timing": {
            "trigger_time":     (if $trigger_time == "null" then null else $trigger_time end),
            "job_started_at":   (if $job_started_at == "null" then null else $job_started_at end),
            "bench_started_at": $bench_started_at,
            "queue_seconds":    $queue_secs,
            "setup_seconds":    $setup_secs,
            "total_seconds":    $total_secs
        },
        "system": {
            "os":        $os_name,
            "os_version": $os_version,
            "arch":      $arch,
            "processor": $processor,
            "vcpus":     $vcpus,
            "ram_mb":    $ram_mb,
            "load_avg":  $load_avg
        }
    }' > "$OUTPUT_FILE"

log "  Result written to ${OUTPUT_FILE}"

# Validate the result file if the validation script exists
VALIDATE_SCRIPT="${PROJECT_ROOT}/scripts/validate-result.sh"
if [[ -f "$VALIDATE_SCRIPT" ]]; then
    log "Validating result file..."
    if bash "$VALIDATE_SCRIPT" "$OUTPUT_FILE"; then
        log "  Validation passed"
    else
        log "  WARNING: Validation failed — result file may be malformed"
    fi
fi

# ---------------------------------------------------------------------------
# Regenerate results/summary.md from all raw JSON files
#
# Deduplication: only the MOST RECENT run per (provider, runner) pair is shown
# in the summary table. All raw JSON files are kept for historical analysis.
# ---------------------------------------------------------------------------
log "Regenerating summary..."

SUMMARY_FILE="${RESULTS_DIR}/summary.md"

{
    echo "# CI Benchmark Results"
    echo ""
    echo "Last updated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""
    echo "Showing the most recent run per provider/runner combination."
    echo "Full history is available in [\`results/raw/\`](raw/)."
    echo ""
    echo "| Provider | Runner | OS | CPU Score (median) | CPU Stddev | Memory (median) | Mem Stddev | Disk (composite) | Disk Stddev | Processor | vCPUs | RAM |"
    echo "|----------|--------|----|--------------------|------------|-----------------|------------|-------------------|-------------|-----------|-------|-----|"
} > "$SUMMARY_FILE"

# Strategy: emit tab-separated rows with timestamp, then sort to pick the
# latest row per (provider, runner) pair, then sort by CPU score descending.
ALL_ROWS=""
for json_file in "${RAW_DIR}"/*.json; do
    [[ -f "$json_file" ]] || continue
    row="$(jq -r '
        [
            .provider // "unknown",
            .runner // "default",
            .timestamp // "1970-01-01T00:00:00Z",
            (.system.os_version // "unknown"),
            ((.benchmarks.cpu.median // 0) | tostring),
            ((.benchmarks.cpu.stddev // 0) | tostring),
            ((.benchmarks.memory.median // 0) | tostring),
            ((.benchmarks.memory.stddev // 0) | tostring),
            ((.benchmarks.disk.composite.median // 0) | tostring),
            ((.benchmarks.disk.composite.stddev // 0) | tostring),
            .system.processor // "unknown",
            ((.system.vcpus // 0) | tostring),
            ((.system.ram_mb // 0) | tostring)
        ] | join("\t")
    ' "$json_file" 2>/dev/null)" || continue
    ALL_ROWS+="${row}"$'\n'
done

if [[ -n "$ALL_ROWS" ]]; then
    # Deduplicate: for each (provider, runner) pair, keep only the row with
    # the latest timestamp. We sort by provider+runner+timestamp, then use
    # awk to keep the last (newest) entry per group.
    DEDUPED="$(printf '%s' "$ALL_ROWS" \
        | sort -t$'\t' -k1,1 -k2,2 -k3,3 \
        | awk -F'\t' '{
            key = $1 "\t" $2
            rows[key] = $0
          }
          END {
            for (key in rows) print rows[key]
          }'
    )"

    # Sort by CPU median score (field 4) descending, then format as Markdown
    printf '%s\n' "$DEDUPED" \
        | sort -t$'\t' -k5 -rn \
        | while IFS=$'\t' read -r r_provider r_runner r_ts r_os r_cpu r_cpu_sd r_mem r_mem_sd r_disk r_disk_sd r_proc r_vcpus r_ram; do
            # Format memory column: show "—" if no memory data (value is 0)
            if [[ "$r_mem" == "0" ]]; then
                mem_display="—"
                mem_sd_display="—"
            else
                mem_display="${r_mem} MiB/sec"
                mem_sd_display="±${r_mem_sd}"
            fi
            # Format disk column: show "—" if no disk data (value is 0)
            if [[ "$r_disk" == "0" ]]; then
                disk_display="—"
                disk_sd_display="—"
            else
                disk_display="${r_disk}"
                disk_sd_display="±${r_disk_sd}"
            fi
            printf '| %s | %s | %s | %s events/sec | ±%s | %s | %s | %s | %s | %s | %s | %s MB |\n' \
                "$r_provider" "$r_runner" "$r_os" "$r_cpu" "$r_cpu_sd" "$mem_display" "$mem_sd_display" "$disk_display" "$disk_sd_display" "$r_proc" "$r_vcpus" "$r_ram"
          done >> "$SUMMARY_FILE"
fi

# Append run count
TOTAL_RUNS=$(find "$RAW_DIR" -name '*.json' -type f 2>/dev/null | wc -l | xargs)
{
    echo ""
    echo "---"
    echo "*${TOTAL_RUNS} total run(s) recorded.*"
} >> "$SUMMARY_FILE"

log "  Summary written to ${SUMMARY_FILE}"

# ---------------------------------------------------------------------------
# Generate docs/data.json for the dashboard
# ---------------------------------------------------------------------------
log "Generating dashboard data..."

DOCS_DIR="${RESULTS_BASE}/docs"
mkdir -p "$DOCS_DIR"

# Consolidate all raw JSON files into a single array, sorted by timestamp descending
if compgen -G "${RAW_DIR}/*.json" > /dev/null; then
    jq -s 'sort_by(.timestamp) | reverse' "${RAW_DIR}"/*.json > "${DOCS_DIR}/data.json"
    log "  Dashboard data written to ${DOCS_DIR}/data.json"
else
    echo '[]' > "${DOCS_DIR}/data.json"
    log "  No raw data found — wrote empty array to ${DOCS_DIR}/data.json"
fi

OVERALL_ELAPSED=$(( $(date +%s) - OVERALL_START ))
log "Done. Total runtime: ${OVERALL_ELAPSED}s"
