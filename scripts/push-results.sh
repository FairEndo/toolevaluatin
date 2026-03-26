#!/usr/bin/env bash
set -euo pipefail

# push-results.sh
# Single source of truth for committing and pushing benchmark results to GitHub.
# Called by all CI providers (GitHub Actions, CircleCI, GitLab CI) after benchmarks run.

# ---------------------------------------------------------------------------
# Arguments & defaults
# ---------------------------------------------------------------------------
PROVIDER="${1:?Usage: push-results.sh <provider> <runner>}"
RUNNER="${2:?Usage: push-results.sh <provider> <runner>}"

RESULTS_CLONE_DIR="${RESULTS_CLONE_DIR:-/tmp/results-repo}"
CI_BENCH_DEBUG="${CI_BENCH_DEBUG:-false}"

MAX_PUSH_ATTEMPTS=3

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[push-results] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

debug_log() {
  if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
    log "[DEBUG] $*"
  fi
}

debug_cmd() {
  if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
    local label="$1"
    shift
    log "[DEBUG] --- ${label} ---"
    "$@" 2>&1 | while IFS= read -r line; do
      log "[DEBUG]   ${line}"
    done
  fi
}

# ---------------------------------------------------------------------------
# 1. Validate clone directory
# ---------------------------------------------------------------------------
log "Provider: ${PROVIDER}"
log "Runner:   ${RUNNER}"
log "Clone dir: ${RESULTS_CLONE_DIR}"

if [[ ! -d "$RESULTS_CLONE_DIR" ]]; then
  log "ERROR: Clone directory does not exist: ${RESULTS_CLONE_DIR}"
  exit 2
fi

if [[ ! -d "$RESULTS_CLONE_DIR/.git" ]]; then
  log "ERROR: Directory is not a git repository: ${RESULTS_CLONE_DIR}"
  exit 2
fi

log "Clone directory validated — is a git repo"

# ---------------------------------------------------------------------------
# 2. cd into clone directory
# ---------------------------------------------------------------------------
cd "$RESULTS_CLONE_DIR"
log "Changed directory to ${RESULTS_CLONE_DIR}"

# ---------------------------------------------------------------------------
# 3. Configure git user
# ---------------------------------------------------------------------------
git config user.name "CI Benchmark Bot"
git config user.email "ci-benchmark-bot@users.noreply.github.com"
log "Configured git user: CI Benchmark Bot <ci-benchmark-bot@users.noreply.github.com>"

# ---------------------------------------------------------------------------
# 4. Debug: git status before staging
# ---------------------------------------------------------------------------
debug_cmd "git status before staging" git status

# ---------------------------------------------------------------------------
# 5. Stage results/ and docs/
# ---------------------------------------------------------------------------
log "Staging results/ and docs/ ..."
git add results/ docs/
log "Staging complete"

# ---------------------------------------------------------------------------
# 6. Log diff --cached --stat
# ---------------------------------------------------------------------------
log "Files staged for commit:"
diff_stat="$(git diff --cached --stat)"
if [[ -n "$diff_stat" ]]; then
  while IFS= read -r line; do
    log "  ${line}"
  done <<< "$diff_stat"
else
  log "  (none)"
fi

# ---------------------------------------------------------------------------
# 7. Count new/modified files
# ---------------------------------------------------------------------------
file_count="$(git diff --cached --name-only | wc -l | tr -d ' ')"
log "Number of new/modified files being committed: ${file_count}"

# ---------------------------------------------------------------------------
# 8. Check if there is anything to commit
# ---------------------------------------------------------------------------
if [[ "$file_count" -eq 0 ]]; then
  log "Nothing to commit — benchmark results are unchanged"
  exit 0
fi

# ---------------------------------------------------------------------------
# 9. Commit
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
COMMIT_MSG="benchmark: ${PROVIDER} (${RUNNER}) - ${TIMESTAMP}"
log "Committing with message: ${COMMIT_MSG}"
git commit -m "$COMMIT_MSG"
log "Commit created successfully"

# ---------------------------------------------------------------------------
# 10. Debug: git log before pushing
# ---------------------------------------------------------------------------
debug_cmd "git log --oneline -5 before pushing" git log --oneline -5

# ---------------------------------------------------------------------------
# 11. Push with retry logic (up to 3 attempts)
# ---------------------------------------------------------------------------
push_succeeded=false
for attempt in $(seq 1 "$MAX_PUSH_ATTEMPTS"); do
  log "Push attempt ${attempt}/${MAX_PUSH_ATTEMPTS} ..."

  push_output=""
  push_exit=0
  push_output="$(git push origin main 2>&1)" || push_exit=$?

  if [[ "$push_exit" -eq 0 ]]; then
    push_succeeded=true
    log "Push succeeded on attempt ${attempt}"
    break
  fi

  # -- Push failed ----------------------------------------------------------
  log "Push attempt ${attempt} failed (exit code ${push_exit})"
  if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
    log "[DEBUG] Full git push error output:"
    while IFS= read -r line; do
      log "[DEBUG]   ${line}"
    done <<< "$push_output"
  fi

  if [[ "$attempt" -eq "$MAX_PUSH_ATTEMPTS" ]]; then
    log "ERROR: All ${MAX_PUSH_ATTEMPTS} push attempts exhausted"
    break
  fi

  # -- Pull --rebase --------------------------------------------------------
  log "Attempting git pull --rebase origin main ..."
  rebase_output=""
  rebase_exit=0
  rebase_output="$(git pull --rebase origin main 2>&1)" || rebase_exit=$?

  if [[ "$rebase_exit" -ne 0 ]]; then
    log "Rebase conflict detected — auto-resolving generated files"
    if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
      log "[DEBUG] Rebase output:"
      while IFS= read -r line; do
        log "[DEBUG]   ${line}"
      done <<< "$rebase_output"
    fi

    # Resolve by keeping our versions of generated files
    git checkout --theirs results/ docs/ 2>/dev/null || true
    git add results/ docs/

    # Attempt to continue the rebase
    continue_output=""
    continue_exit=0
    continue_output="$(git rebase --continue 2>&1)" || continue_exit=$?

    if [[ "$continue_exit" -ne 0 ]]; then
      log "git rebase --continue failed — aborting rebase"
      if [[ "$CI_BENCH_DEBUG" == "true" ]]; then
        log "[DEBUG] rebase --continue output:"
        while IFS= read -r line; do
          log "[DEBUG]   ${line}"
        done <<< "$continue_output"
      fi
      git rebase --abort 2>/dev/null || true
      log "Rebase aborted, will retry on next attempt"
      continue
    fi

    log "Rebase conflict resolved successfully"
  else
    log "Rebase completed without conflicts"
  fi
done

# ---------------------------------------------------------------------------
# 12. Final result
# ---------------------------------------------------------------------------
if [[ "$push_succeeded" != "true" ]]; then
  log "ERROR: Failed to push results after ${MAX_PUSH_ATTEMPTS} attempts"
  exit 1
fi

PUSHED_SHA="$(git rev-parse HEAD)"
log "Pushed commit: ${PUSHED_SHA}"
log "Succeeded on attempt: ${attempt}"
log "Done"
