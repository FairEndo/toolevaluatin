#!/usr/bin/env bash
set -euo pipefail

# clone-results.sh — Clone the CI benchmark results repository and validate the clone.
# Called by all CI providers (GitHub Actions, CircleCI, GitLab CI) before running benchmarks.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[clone-results] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

die() {
  local exit_code="$1"; shift
  log "ERROR: $*" >&2
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# 1. Validate RESULTS_REPO_TOKEN
# ---------------------------------------------------------------------------

if [[ -z "${RESULTS_REPO_TOKEN:-}" ]]; then
  die 1 "RESULTS_REPO_TOKEN is not set." \
        "Set it to a GitHub token with push access to the results repository." \
        "For GitHub Actions, add it as a repository secret. For CircleCI/GitLab, add it as a project environment variable."
fi

log "RESULTS_REPO_TOKEN is set"

# ---------------------------------------------------------------------------
# 2. Determine RESULTS_REPO (auto-detect from CI provider if not explicit)
# ---------------------------------------------------------------------------

RESULTS_REPO="${RESULTS_REPO:-}"

if [[ -n "$RESULTS_REPO" ]]; then
  log "RESULTS_REPO explicitly set to '${RESULTS_REPO}'"
elif [[ -n "${CIRCLE_PROJECT_USERNAME:-}" ]]; then
  RESULTS_REPO="${CIRCLE_PROJECT_USERNAME}/ci-benchmark-results"
  log "Detected CircleCI — derived RESULTS_REPO='${RESULTS_REPO}'"
elif [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
  RESULTS_REPO="${GITHUB_REPOSITORY_OWNER}/ci-benchmark-results"
  log "Detected GitHub Actions — derived RESULTS_REPO='${RESULTS_REPO}'"
elif [[ -n "${CI_PROJECT_NAMESPACE:-}" ]]; then
  RESULTS_REPO="${CI_PROJECT_NAMESPACE}/ci-benchmark-results"
  log "Detected GitLab CI — derived RESULTS_REPO='${RESULTS_REPO}'"
else
  die 1 "Cannot determine RESULTS_REPO." \
        "Set the RESULTS_REPO environment variable (e.g. 'owner/ci-benchmark-results')," \
        "or run this script inside a supported CI environment (GitHub Actions, CircleCI, GitLab CI)."
fi

# ---------------------------------------------------------------------------
# 3. Resolve clone directory
# ---------------------------------------------------------------------------

RESULTS_CLONE_DIR="${RESULTS_CLONE_DIR:-/tmp/results-repo}"

log "Clone directory: ${RESULTS_CLONE_DIR}"

# ---------------------------------------------------------------------------
# 4. Clean up any previous clone
# ---------------------------------------------------------------------------

if [[ -d "$RESULTS_CLONE_DIR" ]]; then
  log "Clone directory already exists — removing it"
  rm -rf "$RESULTS_CLONE_DIR"
fi

# ---------------------------------------------------------------------------
# 5. Clone the results repo
# ---------------------------------------------------------------------------

CLONE_URL="https://x-access-token:${RESULTS_REPO_TOKEN}@github.com/${RESULTS_REPO}.git"
MASKED_URL="https://x-access-token:****@github.com/${RESULTS_REPO}.git"

log "Cloning ${MASKED_URL} into ${RESULTS_CLONE_DIR}"

if ! git clone --single-branch "$CLONE_URL" "$RESULTS_CLONE_DIR" 2>&1 | sed "s/${RESULTS_REPO_TOKEN}/****/g"; then
  die 2 "git clone failed." \
        "Check that RESULTS_REPO_TOKEN has push access to https://github.com/${RESULTS_REPO} and that the repository exists."
fi

log "Clone completed"

# ---------------------------------------------------------------------------
# 6. Validate the clone
# ---------------------------------------------------------------------------

# 6a. Directory must exist
if [[ ! -d "$RESULTS_CLONE_DIR" ]]; then
  die 3 "Validation failed: clone directory '${RESULTS_CLONE_DIR}' does not exist after clone"
fi

# 6b. Ensure results/raw/ exists
RAW_DIR="${RESULTS_CLONE_DIR}/results/raw"
if [[ ! -d "$RAW_DIR" ]]; then
  log "results/raw/ directory missing — creating it"
  mkdir -p "$RAW_DIR"
else
  log "results/raw/ directory exists"
fi

# 6c. Log HEAD SHA for traceability
HEAD_SHA="$(git -C "$RESULTS_CLONE_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")"
log "Results repo HEAD: ${HEAD_SHA}"

# 6d. Count existing result files
FILE_COUNT="$(find "$RAW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
log "Existing result files in results/raw/: ${FILE_COUNT}"

# ---------------------------------------------------------------------------
# 7. Export CI_BENCH_RESULTS_DIR for downstream scripts (e.g. run.sh)
# ---------------------------------------------------------------------------

export CI_BENCH_RESULTS_DIR="$RESULTS_CLONE_DIR"
log "Exported CI_BENCH_RESULTS_DIR=${CI_BENCH_RESULTS_DIR}"

log "Done — results repo is ready"
