#!/usr/bin/env bash
set -euo pipefail

##
# network.sh — Network I/O benchmark driver (curl download throughput)
#
# Usage:
#   network.sh <iterations> [download_bytes] [warmup]
#
# Arguments:
#   iterations      Number of measured runs
#   download_bytes  Size of the test download in bytes (default: 26214400 = 25 MiB)
#   warmup          "true" or "false" — run one throwaway iteration first (default: true)
#
# Runs 2 sub-tests per iteration:
#   1. Download throughput  (MB/s) — sustained transfer from a CDN endpoint
#   2. Latency / TTFB       (ms)  — time-to-first-byte on a minimal request
#
# The composite score equals the download throughput — the primary metric
# that affects CI pipeline setup speed (dependency installs, Docker pulls,
# artifact downloads).
#
# Test endpoints (tried in order):
#   1. Cloudflare speed-test CDN  (globally distributed, purpose-built)
#   2. Hetzner mirror             (reliable European fallback)
#
# Override the download URL via CI_BENCH_NETWORK_URL if your runners
# have restricted egress or you want to test against a private endpoint.
#
# Stdout:  single JSON object with results
# Stderr:  human-readable progress messages
##

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: network.sh <iterations> [download_bytes] [warmup]" >&2
  exit 1
fi

iterations="$1"
download_bytes="${2:-26214400}"   # 25 MiB
warmup="${3:-true}"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: iterations must be a positive integer, got '${iterations}'" >&2
  exit 1
fi

if ! [[ "$download_bytes" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: download_bytes must be a positive integer, got '${download_bytes}'" >&2
  exit 1
fi

download_mib=$(awk "BEGIN { printf \"%.2f\", ${download_bytes} / 1048576 }")

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in curl jq awk; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Resolve test URLs
# ---------------------------------------------------------------------------
# Users can force a specific URL (useful behind corporate proxies / firewalls)
CUSTOM_URL="${CI_BENCH_NETWORK_URL:-}"

# Candidate download URLs, tried in order.  The first one that responds to a
# 1-byte probe within 5 seconds wins.
CANDIDATE_DOWNLOAD_URLS=(
  "https://speed.cloudflare.com/__down?bytes=${download_bytes}"
  "https://ash-speed.hetzner.com/100MB.bin"
)

# Matching latency-probe URLs (tiny payload, same CDN / host)
CANDIDATE_LATENCY_URLS=(
  "https://speed.cloudflare.com/__down?bytes=1"
  "https://ash-speed.hetzner.com/100MB.bin"
)

probe_url() {
  local url="$1"
  curl -fsSL -o /dev/null --max-time 5 --range 0-0 "$url" 2>/dev/null
}

DOWNLOAD_URL=""
LATENCY_URL=""

if [[ -n "$CUSTOM_URL" ]]; then
  DOWNLOAD_URL="$CUSTOM_URL"
  LATENCY_URL="$CUSTOM_URL"
  echo "Using custom URL: ${CUSTOM_URL}" >&2
else
  for idx in "${!CANDIDATE_DOWNLOAD_URLS[@]}"; do
    candidate="${CANDIDATE_DOWNLOAD_URLS[$idx]}"
    echo "Probing ${candidate} ..." >&2
    if probe_url "$candidate"; then
      DOWNLOAD_URL="$candidate"
      LATENCY_URL="${CANDIDATE_LATENCY_URLS[$idx]}"
      echo "  -> reachable, selected as test endpoint" >&2
      break
    else
      echo "  -> unreachable, trying next" >&2
    fi
  done
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "Error: all test endpoints are unreachable — cannot run network benchmark" >&2
  echo "Set CI_BENCH_NETWORK_URL to a reachable URL that serves at least ${download_bytes} bytes." >&2
  exit 1
fi

echo "Download URL: ${DOWNLOAD_URL}" >&2
echo "Latency URL:  ${LATENCY_URL}" >&2
echo "Download size: ${download_mib} MiB (${download_bytes} bytes)" >&2

# ---------------------------------------------------------------------------
# Helper: curl write-out template (avoids repeated string in every call)
# ---------------------------------------------------------------------------
# %{speed_download} → average download speed in bytes/sec
# %{time_starttransfer} → time to first byte in seconds
# %{size_download} → total bytes downloaded
# %{http_code} → HTTP status code
CURL_FMT='%{speed_download}\t%{time_starttransfer}\t%{size_download}\t%{http_code}\n'

# ---------------------------------------------------------------------------
# Helper: run one full iteration (download + latency), print two values
#   <download_mbps> <latency_ms>
# ---------------------------------------------------------------------------
run_once() {
  # -- 1. Download throughput --------------------------------------------------
  local dl_out
  dl_out=$(curl -fsSL -o /dev/null -w "$CURL_FMT" --max-time 120 "$DOWNLOAD_URL" 2>/dev/null) || {
    echo "Error: download request failed" >&2
    return 1
  }

  local dl_speed_bps dl_ttfb dl_size dl_http
  IFS=$'\t' read -r dl_speed_bps dl_ttfb dl_size dl_http <<< "$dl_out"

  if [[ "$dl_http" -lt 200 || "$dl_http" -ge 400 ]]; then
    echo "Error: download returned HTTP ${dl_http}" >&2
    return 1
  fi

  # Convert bytes/sec → MB/sec (base-10 megabytes, matching common CI output)
  local dl_mbps
  dl_mbps=$(awk "BEGIN { v = ${dl_speed_bps} / 1000000; printf \"%.2f\", (v < 0 ? 0 : v) }")

  # -- 2. Latency (TTFB) -------------------------------------------------------
  local lat_out
  lat_out=$(curl -fsSL -o /dev/null -w "$CURL_FMT" --max-time 10 "$LATENCY_URL" 2>/dev/null) || {
    echo "Error: latency request failed" >&2
    return 1
  }

  local lat_speed lat_ttfb lat_size lat_http
  IFS=$'\t' read -r lat_speed lat_ttfb lat_size lat_http <<< "$lat_out"

  # Convert seconds → milliseconds
  local lat_ms
  lat_ms=$(awk "BEGIN { v = ${lat_ttfb} * 1000; printf \"%.2f\", (v < 0 ? 0 : v) }")

  echo "${dl_mbps} ${lat_ms}"
}

# ---------------------------------------------------------------------------
# Helper: compute stats for a single metric array
#   calc_stats "val1 val2 val3 ..." → prints: median min max stddev
# ---------------------------------------------------------------------------
calc_stats() {
  local values_str="$1"
  local sorted
  # shellcheck disable=SC2207
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

  # stddev (population)
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
  warmup_result=$(run_once)
  read -r warmup_dl warmup_lat <<< "$warmup_result"
  echo "  -> ${warmup_dl} MB/s download, ${warmup_lat} ms TTFB (discarded)" >&2
fi

# ---------------------------------------------------------------------------
# Measured runs
# ---------------------------------------------------------------------------
all_download=()
all_latency=()

for ((i = 1; i <= iterations; i++)); do
  echo "Running network benchmark (iteration ${i}/${iterations})..." >&2
  result=$(run_once)
  read -r dl lat <<< "$result"

  all_download+=("$dl")
  all_latency+=("$lat")

  echo "  download: ${dl} MB/s" >&2
  echo "  latency:  ${lat} ms" >&2
done

# ---------------------------------------------------------------------------
# Calculate statistics for each metric
# ---------------------------------------------------------------------------
read -r dl_median dl_min dl_max dl_stddev   <<< "$(calc_stats "${all_download[*]}")"
read -r lat_median lat_min lat_max lat_stddev <<< "$(calc_stats "${all_latency[*]}")"

# ---------------------------------------------------------------------------
# Build JSON output
# ---------------------------------------------------------------------------
dl_scores_json=$(printf '%s\n' "${all_download[@]}" | jq -s '.')
lat_scores_json=$(printf '%s\n' "${all_latency[@]}" | jq -s '.')

# Mask the URL to avoid leaking custom endpoints in result files
display_url="$DOWNLOAD_URL"
if [[ -n "$CUSTOM_URL" ]]; then
  display_url="(custom)"
fi

jq -n \
  --arg tool              "curl" \
  --arg test_url          "$display_url" \
  --argjson download_bytes "$download_bytes" \
  --argjson iters         "$iterations" \
  --argjson dl_scores     "$dl_scores_json" \
  --argjson dl_median     "$dl_median" \
  --argjson dl_min        "$dl_min" \
  --argjson dl_max        "$dl_max" \
  --argjson dl_stddev     "$dl_stddev" \
  --argjson lat_scores    "$lat_scores_json" \
  --argjson lat_median    "$lat_median" \
  --argjson lat_min       "$lat_min" \
  --argjson lat_max       "$lat_max" \
  --argjson lat_stddev    "$lat_stddev" \
  '{
    tool:              $tool,
    test_url:          $test_url,
    download_bytes:    $download_bytes,
    iterations:        $iters,
    composite: {
      scores:  $dl_scores,
      median:  $dl_median,
      min:     $dl_min,
      max:     $dl_max,
      stddev:  $dl_stddev,
      unit:    "MB/s"
    },
    download: {
      scores:  $dl_scores,
      median:  $dl_median,
      min:     $dl_min,
      max:     $dl_max,
      stddev:  $dl_stddev,
      unit:    "MB/s"
    },
    latency: {
      scores:  $lat_scores,
      median:  $lat_median,
      min:     $lat_min,
      max:     $lat_max,
      stddev:  $lat_stddev,
      unit:    "ms"
    }
  }'
