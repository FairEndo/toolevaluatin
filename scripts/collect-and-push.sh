#!/usr/bin/env bash
set -euo pipefail

# collect-and-push.sh
#
# Consolidates benchmark result artifacts from parallel CI jobs into the
# results repository and pushes a single commit.  Designed to be called by
# a "collect-results" job that runs after all benchmark matrix jobs finish.
#
# Usage:
#   collect-and-push.sh <artifacts-dir> <provider> <label>
#
# Arguments:
#   artifacts-dir  Directory containing result JSON files from parallel jobs
#   provider       Provider name for the commit message (e.g. "github-actions")
#   label          Human label for the commit message (e.g. "matrix", "all")
#
# Prerequisites:
#   - The results repo must already be cloned (run scripts/clone-results.sh first)
#   - jq must be installed
#   - RESULTS_CLONE_DIR must point to the cloned results repo (default: /tmp/results-repo)
#
# What this script does:
#   1. Copies new result JSON files into results/raw/
#   2. Regenerates results/summary.md from ALL raw files
#   3. Regenerates docs/data.json from ALL raw files
#   4. Commits and pushes via scripts/push-results.sh

# ---------------------------------------------------------------------------
# Arguments & defaults
# ---------------------------------------------------------------------------
ARTIFACTS_DIR="${1:?Usage: collect-and-push.sh <artifacts-dir> <provider> <label>}"
PROVIDER="${2:?Usage: collect-and-push.sh <artifacts-dir> <provider> <label>}"
LABEL="${3:?Usage: collect-and-push.sh <artifacts-dir> <provider> <label>}"

RESULTS_CLONE_DIR="${RESULTS_CLONE_DIR:-/tmp/results-repo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[collect] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

die() {
  local code="$1"; shift
  log "ERROR: $*" >&2
  exit "$code"
}

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------
log "Provider: ${PROVIDER}"
log "Label:    ${LABEL}"
log "Artifacts directory: ${ARTIFACTS_DIR}"
log "Results clone directory: ${RESULTS_CLONE_DIR}"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  die 1 "Artifacts directory does not exist: ${ARTIFACTS_DIR}"
fi

if [[ ! -d "$RESULTS_CLONE_DIR" ]]; then
  die 1 "Results clone directory does not exist: ${RESULTS_CLONE_DIR} — run scripts/clone-results.sh first"
fi

if [[ ! -d "$RESULTS_CLONE_DIR/.git" ]]; then
  die 1 "Results clone directory is not a git repo: ${RESULTS_CLONE_DIR}"
fi

if ! command -v jq &>/dev/null; then
  die 1 "jq is required but not found in PATH"
fi

# ---------------------------------------------------------------------------
# 2. Find result JSON files in the artifacts directory
# ---------------------------------------------------------------------------
# Some CI systems (GitHub Actions download-artifact) may nest files in
# subdirectories.  We search recursively for any .json file.
mapfile -t JSON_FILES < <(find "$ARTIFACTS_DIR" -type f -name '*.json' | sort)

if [[ ${#JSON_FILES[@]} -eq 0 ]]; then
  log "WARNING: No JSON files found in ${ARTIFACTS_DIR} — nothing to collect"
  exit 0
fi

log "Found ${#JSON_FILES[@]} result file(s) to collect:"
for f in "${JSON_FILES[@]}"; do
  log "  $(basename "$f")"
done

# ---------------------------------------------------------------------------
# 3. Copy result files into results/raw/
# ---------------------------------------------------------------------------
RAW_DIR="${RESULTS_CLONE_DIR}/results/raw"
mkdir -p "$RAW_DIR"

COPIED=0
SKIPPED=0
for f in "${JSON_FILES[@]}"; do
  dest="${RAW_DIR}/$(basename "$f")"
  if [[ -f "$dest" ]]; then
    log "  SKIP (already exists): $(basename "$f")"
    (( SKIPPED++ )) || true
  else
    cp "$f" "$dest"
    (( COPIED++ )) || true
  fi
done

log "Copied ${COPIED} new file(s), skipped ${SKIPPED} existing"

if [[ "$COPIED" -eq 0 ]]; then
  log "No new files to add — nothing to push"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Regenerate results/summary.md
# ---------------------------------------------------------------------------
log "Regenerating summary.md ..."

RESULTS_DIR="${RESULTS_CLONE_DIR}/results"
SUMMARY_FILE="${RESULTS_DIR}/summary.md"

{
  echo "# CI Benchmark Results"
  echo ""
  echo "Last updated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo ""
  echo "Showing the most recent run per provider/runner combination."
  echo "Full history is available in [\`results/raw/\`](raw/)."
  echo ""
  echo "| Provider | Runner | CPU Score (median) | CPU Stddev | Memory (median) | Mem Stddev | Disk (composite) | Disk Stddev | Network (median) | Net Stddev | Processor | vCPUs | RAM |"
  echo "|----------|--------|--------------------|------------|-----------------|------------|-------------------|-------------|------------------|------------|-----------|-------|-----|"
} > "$SUMMARY_FILE"

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
      ((.benchmarks.memory.median // 0) | tostring),
      ((.benchmarks.memory.stddev // 0) | tostring),
      ((.benchmarks.disk.composite.median // 0) | tostring),
      ((.benchmarks.disk.composite.stddev // 0) | tostring),
      ((.benchmarks.network.composite.median // 0) | tostring),
      ((.benchmarks.network.composite.stddev // 0) | tostring),
      .system.processor // "unknown",
      ((.system.vcpus // 0) | tostring),
      ((.system.ram_mb // 0) | tostring)
    ] | join("\t")
  ' "$json_file" 2>/dev/null)" || continue
  ALL_ROWS+="${row}"$'\n'
done

if [[ -n "$ALL_ROWS" ]]; then
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

  printf '%s\n' "$DEDUPED" \
    | sort -t$'\t' -k4 -rn \
    | while IFS=$'\t' read -r r_provider r_runner r_ts r_cpu r_cpu_sd r_mem r_mem_sd r_disk r_disk_sd r_net r_net_sd r_proc r_vcpus r_ram; do
        if [[ "$r_mem" == "0" ]]; then
          mem_display="—"
          mem_sd_display="—"
        else
          mem_display="${r_mem} MiB/sec"
          mem_sd_display="±${r_mem_sd}"
        fi
        if [[ "$r_disk" == "0" ]]; then
          disk_display="—"
          disk_sd_display="—"
        else
          disk_display="${r_disk}"
          disk_sd_display="±${r_disk_sd}"
        fi
        if [[ "$r_net" == "0" ]]; then
          net_display="—"
          net_sd_display="—"
        else
          net_display="${r_net} MB/s"
          net_sd_display="±${r_net_sd}"
        fi
        printf '| %s | %s | %s events/sec | ±%s | %s | %s | %s | %s | %s | %s | %s | %s | %s MB |\n' \
          "$r_provider" "$r_runner" "$r_cpu" "$r_cpu_sd" "$mem_display" "$mem_sd_display" "$disk_display" "$disk_sd_display" "$net_display" "$net_sd_display" "$r_proc" "$r_vcpus" "$r_ram"
      done >> "$SUMMARY_FILE"
fi

TOTAL_RUNS=$(find "$RAW_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
{
  echo ""
  echo "---"
  echo "*${TOTAL_RUNS} total run(s) recorded.*"
} >> "$SUMMARY_FILE"

log "  Summary written to ${SUMMARY_FILE} (${TOTAL_RUNS} total runs)"

# ---------------------------------------------------------------------------
# 5. Regenerate docs/data.json
# ---------------------------------------------------------------------------
log "Regenerating docs/data.json ..."

DOCS_DIR="${RESULTS_CLONE_DIR}/docs"
mkdir -p "$DOCS_DIR"

if compgen -G "${RAW_DIR}/*.json" > /dev/null; then
  jq -s 'sort_by(.timestamp) | reverse' "${RAW_DIR}"/*.json > "${DOCS_DIR}/data.json"
  DATA_ENTRIES=$(jq 'length' "${DOCS_DIR}/data.json")
  log "  Dashboard data written (${DATA_ENTRIES} entries)"
else
  echo '[]' > "${DOCS_DIR}/data.json"
  log "  No raw data — wrote empty array"
fi

# ---------------------------------------------------------------------------
# 6. Push results using the shared script
# ---------------------------------------------------------------------------
log "Handing off to push-results.sh ..."

export RESULTS_CLONE_DIR
exec bash "${SCRIPT_DIR}/push-results.sh" "${PROVIDER}" "${LABEL}"
