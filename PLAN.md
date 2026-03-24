# CI Benchmarks — Project Plan

## Goal

Compare CPU performance (and eventually more) across CI providers, starting with **GitHub Actions** and **CircleCI**. Results are committed to the repo as raw JSON data + a human-readable Markdown summary.

## Architecture

    .
    ├── PLAN.md
    ├── README.md
    ├── .gitignore
    ├── benchmarks/
    │   ├── run.sh                   # Single entrypoint — all CI configs call this
    │   └── lib/
    │       └── cpu.sh               # CPU benchmark logic (sysbench)
    ├── config/
    │   └── benchmarks.yml           # Flat key-value config for benchmarks
    ├── results/
    │   ├── raw/                     # One JSON file per run (append-only history)
    │   │   └── .gitkeep
    │   └── summary.md               # Auto-generated leaderboard (latest per provider)
    ├── .github/workflows/
    │   └── benchmark.yml            # GitHub Actions (thin wrapper)
    └── .circleci/
        └── config.yml               # CircleCI (thin wrapper)

### Key Principles

> **CI configs are thin wrappers.** They install dependencies and call `./benchmarks/run.sh`. All benchmark logic lives in the scripts.

> **Config is flat YAML.** Simple `key: value` pairs that can be parsed with grep/sed — no YAML library needed.

> **Scripts are called with `bash`**, not relied upon to be executable. This avoids git executable-bit issues across platforms.

## Benchmark: CPU (v1)

| Detail | Decision |
|---|---|
| **Tool** | `sysbench` (free, open source, one-liner install) |
| **Command** | `sysbench cpu --cpu-max-prime=20000 --threads=1 run` |
| **Metric** | Events per second (higher = faster) |
| **Warmup** | 1 throwaway iteration before measured runs (stabilizes CPU frequency/caches) |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation |
| **Additional data** | Processor model, vCPU count, total RAM, system load average |

## CI Providers (v1)

| Provider | Runner | vCPUs | Trigger |
|---|---|---|---|
| GitHub Actions | `ubuntu-latest` | 2 | `workflow_dispatch` (manual via GitHub UI) |
| CircleCI | `medium` resource class | 2 | API trigger with `run_benchmark: true` parameter |

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

- More benchmarks: disk (fio), memory (sysbench), network (iperf3)
- More CI providers: GitLab CI, Buildkite, Jenkins, etc.
- Queue time tracking (record job start vs. trigger time)
- Pricing data and value scoring
- Charts / visualization (SVG generation from JSON data)
- Scheduled runs (cron triggers) for trend tracking