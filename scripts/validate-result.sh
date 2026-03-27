#!/usr/bin/env bash
set -euo pipefail

# validate-result.sh
#
# Validates a benchmark result JSON file to catch corruption or anomalies
# before the results are pushed to the repository.
#
# Usage:
#   validate-result.sh <json-file>
#
# Arguments:
#   json-file   Path to a benchmark result JSON file to validate
#
# Exit codes:
#   0  All validation checks passed
#   1  One or more validation checks failed (or bad usage)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
JSON_FILE="${1:?Usage: validate-result.sh <json-file>}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[validate] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

warn() {
  echo "[validate] $(date -u +"%Y-%m-%dT%H:%M:%SZ") WARNING: $*"
}

# Accumulate failures and warnings
FAILURES=()
WARNINGS=()

fail() {
  FAILURES+=("$1")
}

# ---------------------------------------------------------------------------
# a. File exists and is non-empty
# ---------------------------------------------------------------------------
log "Validating: ${JSON_FILE}"

if [[ ! -f "$JSON_FILE" ]]; then
  fail "File does not exist: ${JSON_FILE}"
elif [[ ! -s "$JSON_FILE" ]]; then
  fail "File is empty: ${JSON_FILE}"
fi

# If the file doesn't exist or is empty, we can't do any further checks,
# but we still report cleanly at the end.
CAN_PARSE=false

# ---------------------------------------------------------------------------
# b. Valid JSON
# ---------------------------------------------------------------------------
if [[ -f "$JSON_FILE" && -s "$JSON_FILE" ]]; then
  if jq . < "$JSON_FILE" > /dev/null 2>&1; then
    CAN_PARSE=true
  else
    fail "File is not valid JSON"
  fi
fi

# ---------------------------------------------------------------------------
# All remaining checks require parseable JSON
# ---------------------------------------------------------------------------
if [[ "$CAN_PARSE" == true ]]; then

  # Helper: read a jq expression and return the raw output
  jq_raw() {
    jq -r "$1" < "$JSON_FILE"
  }

  # -------------------------------------------------------------------------
  # c. Required top-level fields exist
  # -------------------------------------------------------------------------
  for field in provider runner timestamp benchmarks system; do
    has=$(jq_raw "has(\"${field}\")")
    if [[ "$has" != "true" ]]; then
      fail "Missing required top-level field: '${field}'"
    fi
  done

  # -------------------------------------------------------------------------
  # d. Provider is not empty/null
  # -------------------------------------------------------------------------
  provider_val=$(jq_raw '.provider // empty')
  if [[ -z "$provider_val" || "$provider_val" == "null" ]]; then
    fail ".provider is empty or null"
  fi

  # -------------------------------------------------------------------------
  # e. Runner is not empty/null
  # -------------------------------------------------------------------------
  runner_val=$(jq_raw '.runner // empty')
  if [[ -z "$runner_val" || "$runner_val" == "null" ]]; then
    fail ".runner is empty or null"
  fi

  # -------------------------------------------------------------------------
  # f. Timestamp is not empty/null
  # -------------------------------------------------------------------------
  timestamp_val=$(jq_raw '.timestamp // empty')
  if [[ -z "$timestamp_val" || "$timestamp_val" == "null" ]]; then
    fail ".timestamp is empty or null"
  fi

  # -------------------------------------------------------------------------
  # g. System info present
  # -------------------------------------------------------------------------
  sys_processor=$(jq_raw '.system.processor // empty')
  if [[ -z "$sys_processor" || "$sys_processor" == "null" ]]; then
    fail ".system.processor is missing or null"
  fi

  sys_vcpus=$(jq_raw '.system.vcpus // empty')
  if [[ -z "$sys_vcpus" ]]; then
    fail ".system.vcpus is missing or null"
  else
    is_pos_int=$(jq_raw '.system.vcpus | if type == "number" and . == floor and . > 0 then "yes" else "no" end')
    if [[ "$is_pos_int" != "yes" ]]; then
      fail ".system.vcpus is not a positive integer (got: ${sys_vcpus})"
    fi
  fi

  sys_ram=$(jq_raw '.system.ram_mb // empty')
  if [[ -z "$sys_ram" ]]; then
    fail ".system.ram_mb is missing or null"
  else
    is_pos_int=$(jq_raw '.system.ram_mb | if type == "number" and . == floor and . > 0 then "yes" else "no" end')
    if [[ "$is_pos_int" != "yes" ]]; then
      fail ".system.ram_mb is not a positive integer (got: ${sys_ram})"
    fi
  fi

  # -------------------------------------------------------------------------
  # g2. OS info (soft check — older results may not have these)
  # -------------------------------------------------------------------------
  sys_os=$(jq_raw '.system.os // empty')
  if [[ -z "$sys_os" || "$sys_os" == "null" ]]; then
    WARNINGS+=(".system.os is missing — older result file?")
    warn ".system.os is missing (may be an older result file)"
  fi

  sys_arch=$(jq_raw '.system.arch // empty')
  if [[ -z "$sys_arch" || "$sys_arch" == "null" ]]; then
    WARNINGS+=(".system.arch is missing — older result file?")
    warn ".system.arch is missing (may be an older result file)"
  fi

  # -------------------------------------------------------------------------
  # h. At least one benchmark present
  # -------------------------------------------------------------------------
  bench_key_count=$(jq_raw '.benchmarks | if type == "object" then keys | length else 0 end')
  if [[ "$bench_key_count" -eq 0 ]]; then
    fail ".benchmarks has no keys (need at least one of cpu, memory)"
  fi

  # -------------------------------------------------------------------------
  # Helper function for validating a benchmark section (cpu or memory)
  # -------------------------------------------------------------------------
  validate_benchmark() {
    local name="$1"    # "cpu" or "memory"
    local unit="$2"    # for display only

    # Check if the section exists
    local exists
    exists=$(jq_raw ".benchmarks.${name} != null")
    if [[ "$exists" != "true" ]]; then
      return
    fi

    log "  Checking .benchmarks.${name} ..."

    # median is a number > 0
    local median_ok
    median_ok=$(jq_raw ".benchmarks.${name}.median | if type == \"number\" and . > 0 then \"yes\" else \"no\" end")
    if [[ "$median_ok" != "yes" ]]; then
      fail ".benchmarks.${name}.median must be a number > 0"
    fi

    # scores is a non-empty array
    local scores_ok
    scores_ok=$(jq_raw ".benchmarks.${name}.scores | if type == \"array\" and length > 0 then \"yes\" else \"no\" end")
    if [[ "$scores_ok" != "yes" ]]; then
      fail ".benchmarks.${name}.scores must be a non-empty array"
    fi

    # scores length matches iterations
    local scores_len iterations
    scores_len=$(jq_raw ".benchmarks.${name}.scores | if type == \"array\" then length else 0 end")
    iterations=$(jq_raw ".benchmarks.${name}.iterations // 0")
    if [[ "$scores_len" -ne "$iterations" ]]; then
      fail ".benchmarks.${name}.scores length (${scores_len}) does not match .benchmarks.${name}.iterations (${iterations})"
    fi

    # min <= median <= max
    local ordering_ok
    ordering_ok=$(jq_raw "
      .benchmarks.${name} |
      if .min != null and .median != null and .max != null
         and .min <= .median and .median <= .max
      then \"yes\" else \"no\" end
    ")
    if [[ "$ordering_ok" != "yes" ]]; then
      local min_v median_v max_v
      min_v=$(jq_raw ".benchmarks.${name}.min // \"null\"")
      median_v=$(jq_raw ".benchmarks.${name}.median // \"null\"")
      max_v=$(jq_raw ".benchmarks.${name}.max // \"null\"")
      fail ".benchmarks.${name}: ordering violation — min (${min_v}) <= median (${median_v}) <= max (${max_v}) does not hold"
    fi

    # stddev is a number >= 0
    local stddev_ok
    stddev_ok=$(jq_raw ".benchmarks.${name}.stddev | if type == \"number\" and . >= 0 then \"yes\" else \"no\" end")
    if [[ "$stddev_ok" != "yes" ]]; then
      fail ".benchmarks.${name}.stddev must be a number >= 0"
    fi

    # -----------------------------------------------------------------------
    # k. Sanity bounds (warnings only)
    # -----------------------------------------------------------------------
    if [[ "$median_ok" == "yes" ]]; then
      local median_val
      median_val=$(jq_raw ".benchmarks.${name}.median")

      local too_high too_low
      too_high=$(jq_raw ".benchmarks.${name}.median > 100000")
      too_low=$(jq_raw ".benchmarks.${name}.median < 1")

      if [[ "$too_high" == "true" ]]; then
        WARNINGS+=(".benchmarks.${name}.median is suspiciously high (${median_val} ${unit})")
        warn ".benchmarks.${name}.median is suspiciously high: ${median_val} ${unit}"
      fi
      if [[ "$too_low" == "true" ]]; then
        WARNINGS+=(".benchmarks.${name}.median is suspiciously low (${median_val} ${unit})")
        warn ".benchmarks.${name}.median is suspiciously low: ${median_val} ${unit}"
      fi
    fi
  }

  # -------------------------------------------------------------------------
  # i. CPU benchmark validation
  # -------------------------------------------------------------------------
  validate_benchmark "cpu" "events/sec"

  # -------------------------------------------------------------------------
  # j. Memory benchmark validation
  # -------------------------------------------------------------------------
  validate_benchmark "memory" "MiB/sec"

  # -------------------------------------------------------------------------
  # k2. Compile benchmark validation
  # -------------------------------------------------------------------------
  validate_benchmark "compile" "seconds"

  # -------------------------------------------------------------------------
  # k. Disk benchmark validation
  # -------------------------------------------------------------------------
  # Disk has a different structure: composite + sub-tests
  disk_exists=$(jq_raw ".benchmarks.disk != null")
  if [[ "$disk_exists" == "true" ]]; then
      log "  Checking .benchmarks.disk ..."

      for sub in composite seq_read seq_write rand_read rand_write; do
          sub_exists=$(jq_raw ".benchmarks.disk.${sub} != null")
          if [[ "$sub_exists" != "true" ]]; then
              fail ".benchmarks.disk.${sub} is missing"
              continue
          fi

          # median > 0
          median_ok=$(jq_raw ".benchmarks.disk.${sub}.median | if type == \"number\" and . > 0 then \"yes\" else \"no\" end")
          if [[ "$median_ok" != "yes" ]]; then
              fail ".benchmarks.disk.${sub}.median must be a number > 0"
          fi

          # scores is non-empty array
          scores_ok=$(jq_raw ".benchmarks.disk.${sub}.scores | if type == \"array\" and length > 0 then \"yes\" else \"no\" end")
          if [[ "$scores_ok" != "yes" ]]; then
              fail ".benchmarks.disk.${sub}.scores must be a non-empty array"
          fi

          # min <= median <= max
          ordering_ok=$(jq_raw "
              .benchmarks.disk.${sub} |
              if .min != null and .median != null and .max != null
                 and .min <= .median and .median <= .max
              then \"yes\" else \"no\" end
          ")
          if [[ "$ordering_ok" != "yes" ]]; then
              min_v=$(jq_raw ".benchmarks.disk.${sub}.min // \"null\"")
              median_v=$(jq_raw ".benchmarks.disk.${sub}.median // \"null\"")
              max_v=$(jq_raw ".benchmarks.disk.${sub}.max // \"null\"")
              fail ".benchmarks.disk.${sub}: ordering violation — min (${min_v}) <= median (${median_v}) <= max (${max_v}) does not hold"
          fi

          # stddev >= 0
          stddev_ok=$(jq_raw ".benchmarks.disk.${sub}.stddev | if type == \"number\" and . >= 0 then \"yes\" else \"no\" end")
          if [[ "$stddev_ok" != "yes" ]]; then
              fail ".benchmarks.disk.${sub}.stddev must be a number >= 0"
          fi
      done
  fi

  # -------------------------------------------------------------------------
  # l. Network benchmark validation
  # -------------------------------------------------------------------------
  # Network has a similar structure to disk: composite + sub-tests
  network_exists=$(jq_raw ".benchmarks.network != null")
  if [[ "$network_exists" == "true" ]]; then
      log "  Checking .benchmarks.network ..."

      for sub in composite download latency; do
          sub_exists=$(jq_raw ".benchmarks.network.${sub} != null")
          if [[ "$sub_exists" != "true" ]]; then
              fail ".benchmarks.network.${sub} is missing"
              continue
          fi

          # median > 0
          median_ok=$(jq_raw ".benchmarks.network.${sub}.median | if type == \"number\" and . > 0 then \"yes\" else \"no\" end")
          if [[ "$median_ok" != "yes" ]]; then
              fail ".benchmarks.network.${sub}.median must be a number > 0"
          fi

          # scores is non-empty array
          scores_ok=$(jq_raw ".benchmarks.network.${sub}.scores | if type == \"array\" and length > 0 then \"yes\" else \"no\" end")
          if [[ "$scores_ok" != "yes" ]]; then
              fail ".benchmarks.network.${sub}.scores must be a non-empty array"
          fi

          # min <= median <= max
          ordering_ok=$(jq_raw "
              .benchmarks.network.${sub} |
              if .min != null and .median != null and .max != null
                 and .min <= .median and .median <= .max
              then \"yes\" else \"no\" end
          ")
          if [[ "$ordering_ok" != "yes" ]]; then
              min_v=$(jq_raw ".benchmarks.network.${sub}.min // \"null\"")
              median_v=$(jq_raw ".benchmarks.network.${sub}.median // \"null\"")
              max_v=$(jq_raw ".benchmarks.network.${sub}.max // \"null\"")
              fail ".benchmarks.network.${sub}: ordering violation — min (${min_v}) <= median (${median_v}) <= max (${max_v}) does not hold"
          fi

          # stddev >= 0
          stddev_ok=$(jq_raw ".benchmarks.network.${sub}.stddev | if type == \"number\" and . >= 0 then \"yes\" else \"no\" end")
          if [[ "$stddev_ok" != "yes" ]]; then
              fail ".benchmarks.network.${sub}.stddev must be a number >= 0"
          fi
      done

      # Sanity: download throughput warnings
      dl_median_ok=$(jq_raw ".benchmarks.network.download.median | if type == \"number\" and . > 0 then \"yes\" else \"no\" end")
      if [[ "$dl_median_ok" == "yes" ]]; then
          dl_median_val=$(jq_raw ".benchmarks.network.download.median")
          dl_too_low=$(jq_raw ".benchmarks.network.download.median < 0.1")
          if [[ "$dl_too_low" == "true" ]]; then
              WARNINGS+=(".benchmarks.network.download.median is suspiciously low (${dl_median_val} MB/s)")
              warn ".benchmarks.network.download.median is suspiciously low: ${dl_median_val} MB/s"
          fi
      fi

      # Sanity: latency warnings
      lat_median_ok=$(jq_raw ".benchmarks.network.latency.median | if type == \"number\" and . > 0 then \"yes\" else \"no\" end")
      if [[ "$lat_median_ok" == "yes" ]]; then
          lat_median_val=$(jq_raw ".benchmarks.network.latency.median")
          lat_too_high=$(jq_raw ".benchmarks.network.latency.median > 5000")
          if [[ "$lat_too_high" == "true" ]]; then
              WARNINGS+=(".benchmarks.network.latency.median is suspiciously high (${lat_median_val} ms)")
              warn ".benchmarks.network.latency.median is suspiciously high: ${lat_median_val} ms"
          fi
      fi
  fi

fi
# End of parseable-JSON checks

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
echo ""

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  log "--- Warnings (${#WARNINGS[@]}) ---"
  for w in "${WARNINGS[@]}"; do
    log "  ⚠  ${w}"
  done
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "--- Failures (${#FAILURES[@]}) ---"
  for f in "${FAILURES[@]}"; do
    log "  ✗  ${f}"
  done
  log "Validation FAILED: ${#FAILURES[@]} error(s) found"
  exit 1
fi

# Build a brief summary for the success message
summary_parts=()
if [[ "$CAN_PARSE" == true ]]; then
  [[ -n "${provider_val:-}" ]] && summary_parts+=("provider=${provider_val}")
  [[ -n "${runner_val:-}" ]]   && summary_parts+=("runner=${runner_val}")

  cpu_median=$(jq_raw '.benchmarks.cpu.median // empty' 2>/dev/null || true)
  mem_median=$(jq_raw '.benchmarks.memory.median // empty' 2>/dev/null || true)
  disk_median=$(jq_raw '.benchmarks.disk.composite.median // empty' 2>/dev/null || true)

  [[ -n "$cpu_median" ]]  && summary_parts+=("cpu_median=${cpu_median}")
  [[ -n "$mem_median" ]]  && summary_parts+=("mem_median=${mem_median}")
  [[ -n "$disk_median" ]] && summary_parts+=("disk_composite_median=${disk_median}")

  net_median=$(jq_raw '.benchmarks.network.composite.median // empty' 2>/dev/null || true)
  [[ -n "$net_median" ]] && summary_parts+=("net_dl_median=${net_median}")
fi

log "Validation PASSED (${summary_parts[*]:-no details})"
exit 0
