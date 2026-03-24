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
#   CI_BENCH_PROVIDER       — provider name (e.g. "github-actions")
#   CI_BENCH_RUNNER         — runner label (e.g. "ubuntu-latest")
#   CI_BENCH_CPU_ENABLED    — "true" / "false"
#   CI_BENCH_ITERATIONS     — number of measured iterations
#   CI_BENCH_CPU_MAX_PRIME  — sysbench cpu-max-prime parameter
#   CI_BENCH_CPU_WARMUP     — "true" / "false"
###############################################################################

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/benchmarks.yml"
LIB_DIR="${SCRIPT_DIR}/lib"
RESULTS_DIR="${PROJECT_ROOT}/results"
RAW_DIR="${RESULTS_DIR}/raw"

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------
log() { printf '[bench] %s\n' "$*"; }

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
else
    log "  Config file not found — using defaults"
    CFG_CPU_ENABLED="true"
    CFG_ITERATIONS="5"
    CFG_CPU_MAX_PRIME="20000"
    CFG_CPU_WARMUP="true"
fi

# Environment variable overrides take precedence
CPU_ENABLED="${CI_BENCH_CPU_ENABLED:-$CFG_CPU_ENABLED}"
ITERATIONS="${CI_BENCH_ITERATIONS:-$CFG_ITERATIONS}"
CPU_MAX_PRIME="${CI_BENCH_CPU_MAX_PRIME:-$CFG_CPU_MAX_PRIME}"
CPU_WARMUP="${CI_BENCH_CPU_WARMUP:-$CFG_CPU_WARMUP}"
PROVIDER="${CI_BENCH_PROVIDER:-unknown}"
RUNNER="${CI_BENCH_RUNNER:-default}"

log "  provider      = ${PROVIDER}"
log "  runner        = ${RUNNER}"
log "  cpu_enabled   = ${CPU_ENABLED}"
log "  iterations    = ${ITERATIONS}"
log "  cpu_max_prime = ${CPU_MAX_PRIME}"
log "  cpu_warmup    = ${CPU_WARMUP}"

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

    CPU_SCRIPT="${LIB_DIR}/cpu.sh"
    CPU_JSON=""

    if [[ -f "$CPU_SCRIPT" ]]; then
        # Delegate to the library script (call with bash to avoid executable-bit issues).
        # cpu.sh <iterations> [cpu_max_prime] [warmup]
        # Stdout = JSON result, stderr = progress messages (shown in CI logs).
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
        BENCHMARKS_JSON="$(jq -n --argjson cpu "$CPU_JSON" '{ "cpu": $cpu }')"
    fi
else
    log "CPU benchmark is disabled — skipping"
fi

# ---------------------------------------------------------------------------
# Build final JSON result
# ---------------------------------------------------------------------------
log "Writing results..."

OUTPUT_FILE="${RAW_DIR}/${PROVIDER}_${TIMESTAMP//[:.]/-}.json"

jq -n \
    --arg provider   "$PROVIDER" \
    --arg runner     "$RUNNER" \
    --arg timestamp  "$TIMESTAMP" \
    --argjson benchmarks "$BENCHMARKS_JSON" \
    --arg processor  "$PROCESSOR" \
    --argjson vcpus  "$VCPUS" \
    --argjson ram_mb "$RAM_MB" \
    --arg load_avg   "$LOAD_AVG" \
    '{
        "provider":   $provider,
        "runner":     $runner,
        "timestamp":  $timestamp,
        "benchmarks": $benchmarks,
        "system": {
            "processor": $processor,
            "vcpus":     $vcpus,
            "ram_mb":    $ram_mb,
            "load_avg":  $load_avg
        }
    }' > "$OUTPUT_FILE"

log "  Result written to ${OUTPUT_FILE}"

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
    echo "| Provider | Runner | CPU Score (median) | Stddev | Processor | vCPUs | RAM |"
    echo "|----------|--------|--------------------|--------|-----------|-------|-----|"
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
            ((.benchmarks.cpu.median // 0) | tostring),
            ((.benchmarks.cpu.stddev // 0) | tostring),
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
        | sort -t$'\t' -k4 -rn \
        | while IFS=$'\t' read -r r_provider r_runner r_ts r_cpu r_stddev r_proc r_vcpus r_ram; do
            printf '| %s | %s | %s events/sec | ±%s | %s | %s | %s MB |\n' \
                "$r_provider" "$r_runner" "$r_cpu" "$r_stddev" "$r_proc" "$r_vcpus" "$r_ram"
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
log "Done."
