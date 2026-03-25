# CI Benchmarks — Project Plan

## Goal

Compare CPU performance (and eventually more) across CI providers — **GitHub Actions**, **CircleCI**, and **GitLab CI**. Results are committed to the repo as raw JSON data + a human-readable Markdown summary.

## Architecture

    .
    ├── PLAN.md
    ├── README.md
    ├── .gitignore
    ├── .gitlab-ci.yml               # GitLab CI (thin wrapper, 5 runner sizes)
    ├── benchmarks/
    │   ├── run.sh                   # Single entrypoint — all CI configs call this
    │   └── lib/
    │       ├── cpu.sh               # CPU benchmark logic (sysbench)
    │       └── memory.sh            # Memory benchmark logic (sysbench)
    ├── config/
    │   └── benchmarks.yml           # Flat key-value config for benchmarks
    ├── results/
    │   ├── raw/                     # One JSON file per run (append-only history)
    │   │   └── .gitkeep
    │   └── summary.md               # Auto-generated leaderboard (latest per provider)
    ├── .github/workflows/
    │   ├── benchmark.yml            # GitHub Actions (thin wrapper)
    │   └── sync-gitlab.yml          # Pushes main to GitLab mirror
    ├── .circleci/
    │   └── config.yml               # CircleCI (thin wrapper)
    └── docs/
        ├── index.html               # Dashboard UI
        └── data.json                # Consolidated results for dashboard

### Key Principles

> **CI configs are thin wrappers.** They install dependencies and call `./benchmarks/run.sh`. All benchmark logic lives in the scripts.

> **Config is flat YAML.** Simple `key: value` pairs that can be parsed with grep/sed — no YAML library needed.

> **Scripts are called with `bash`**, not relied upon to be executable. This avoids git executable-bit issues across platforms.

## Benchmark: CPU

| Detail | Decision |
|---|---|
| **Tool** | `sysbench` (free, open source, one-liner install) |
| **Command** | `sysbench cpu --cpu-max-prime=20000 --threads=1 run` |
| **Metric** | Events per second (higher = faster) |
| **Warmup** | 1 throwaway iteration before measured runs (stabilizes CPU frequency/caches) |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation |
| **Additional data** | Processor model, vCPU count, total RAM, system load average |

## CI Providers

### GitHub Actions

| Runner | Architecture | vCPUs | Trigger |
|---|---|---|---|
| `ubuntu-latest` | x64 | 2 | `workflow_dispatch` single mode (default) or push to `main` |
| `ubuntu-24.04` | x64 | 2 | `workflow_dispatch` matrix mode (`run_matrix: true`) |
| `ubuntu-22.04` | x64 | 2 | `workflow_dispatch` matrix mode (`run_matrix: true`) |
| `ubuntu-latest-4-cores` | x64 | 4 | `workflow_dispatch` matrix mode (`run_matrix: true`) — paid plan |
| `ubuntu-latest-8-cores` | x64 | 8 | `workflow_dispatch` matrix mode (`run_matrix: true`) — paid plan |
| `ubuntu-latest-16-cores` | x64 | 16 | `workflow_dispatch` matrix mode (`run_matrix: true`) — paid plan |
| `macos-latest` | arm64 | 3+ | `workflow_dispatch` matrix mode (`run_matrix: true`) |
| `macos-13` | x64 | 3+ | `workflow_dispatch` matrix mode (`run_matrix: true`) |

### CircleCI

| Resource Class | Architecture | vCPUs | RAM | Trigger |
|---|---|---|---|---|
| `medium` | x64 | 2 | 4 GB | API trigger with `run_benchmark: true` |
| `large` | x64 | 4 | 8 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `xlarge` | x64 | 8 | 16 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `arm.medium` | arm64 | 2 | 4 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `arm.large` | arm64 | 4 | 8 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |

### GitLab CI

> GitLab is used as a CI runner only — GitHub remains the VCS. A GitHub Actions workflow (`sync-gitlab.yml`) pushes `main` to a GitLab mirror on every commit. The GitLab pipeline only runs on manual or API triggers (never on push).

| Runner Tag | Architecture | vCPUs | Trigger |
|---|---|---|---|
| `small-amd64` | x64 | 2 | GitLab UI or API trigger (default) |
| `medium-amd64` | x64 | 4 | GitLab UI or API trigger with `RUN_ALL=true` — paid plan |
| `large-amd64` | x64 | 8 | GitLab UI or API trigger with `RUN_ALL=true` — paid plan |
| `medium-arm64` | arm64 | 4 | GitLab UI or API trigger with `RUN_ALL=true` — paid plan |
| `large-arm64` | arm64 | 8 | GitLab UI or API trigger with `RUN_ALL=true` — paid plan |

## Results

- **Raw data**: JSON files in `results/raw/`, one per run, named `{provider}_{timestamp}.json`
- **Summary**: Auto-generated Markdown table at `results/summary.md`
  - Deduplicated: shows only the **most recent** run per (provider, runner) pair
  - Sorted by CPU score descending
  - Includes units (events/sec) and standard deviation (±)

## Configuration

- **Source of truth**: `config/benchmarks.yml` (flat key-value format)
- **Env var overrides**: `CI_BENCH_PROVIDER`, `CI_BENCH_RUNNER`, `CI_BENCH_CPU_ENABLED`, `CI_BENCH_ITERATIONS`, `CI_BENCH_CPU_MAX_PRIME`, `CI_BENCH_CPU_WARMUP`

## Robustness Features

- **Warmup iteration** prevents cold-start measurement noise
- **5 iterations** with median gives stable signal resistant to outliers
- **Standard deviation** exposes noisy-neighbor environments
- **System load recording** helps flag anomalous runs after the fact
- **Git push retry with rebase** handles concurrent benchmark runs
- **Graceful fallbacks** — run.sh works even if cpu.sh fails (inline sysbench fallback)
- **Cross-platform system info** — Linux primary, macOS fallback for local testing

## Future Expansion

- More benchmarks: disk (fio), network (iperf3)
- More CI providers: Buildkite, Jenkins, etc.
- More GitHub Actions runners: `windows-latest`, self-hosted runners
- More GitLab runners: self-hosted, GPU-enabled
- Queue time tracking (record job start vs. trigger time)
- Pricing data and value scoring (cost per benchmark score)
- Charts / visualization (SVG generation from JSON data)
- Scheduled runs (cron triggers) for trend tracking
- ARM vs x64 performance comparison analysis