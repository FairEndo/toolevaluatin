# CI Benchmarks — Project Plan

## Goal

Compare CPU, memory, disk I/O, compile, and network performance across CI providers — **GitHub Actions**, **CircleCI**, and **GitLab CI**. Results are committed to the repo as raw JSON data + a human-readable Markdown summary.

## Architecture

    ## Benchmarking repo (toolevaluatin)
    .
    ├── PLAN.md
    ├── README.md
    ├── .gitignore
    ├── .gitlab-ci.yml               # GitLab CI (thin wrapper, 5 runner sizes)
    ├── benchmarks/
    │   ├── run.sh                   # Single entrypoint — all CI configs call this
    │   └── lib/
    │       ├── cpu.sh               # CPU benchmark logic (sysbench)
    │       ├── memory.sh            # Memory benchmark logic (sysbench)
    │       ├── disk.sh              # Disk I/O benchmark logic (fio)
    │       ├── compile.sh           # Compile benchmark logic (Redis build)
    │       └── network.sh           # Network benchmark logic (curl download + TTFB)
    ├── config/
    │   └── benchmarks.yml           # Flat key-value config for benchmarks
    ├── .github/workflows/
    │   ├── benchmark.yml            # GitHub Actions (thin wrapper)
    │   └── sync-gitlab.yml          # Pushes main to GitLab mirror
    └── .circleci/
        └── config.yml               # CircleCI (thin wrapper)

    ## Results repo (ci-benchmark-results) — separate repository
    .
    ├── results/
    │   ├── raw/                     # One JSON file per run (append-only history)
    │   │   └── .gitkeep
    │   └── summary.md               # Auto-generated leaderboard (latest per provider)
    └── docs/
        ├── index.html               # Dashboard UI
        └── data.json                # Consolidated results for dashboard

### Key Principles

> **CI configs are thin wrappers.** They install dependencies, clone the results repo, and call `./benchmarks/run.sh`. All benchmark logic lives in the scripts.

> **Results live in a separate repo.** The `ci-benchmark-results` repository stores all raw JSON, the summary, and the dashboard. This keeps the benchmarking repo clean and focused on logic. The `CI_BENCH_RESULTS_DIR` env var tells `run.sh` where to write.

> **Config is flat YAML.** Simple `key: value` pairs that can be parsed with grep/sed — no YAML library needed.

> **Scripts are called with `bash`**, not relied upon to be executable. This avoids git executable-bit issues across platforms.

## Benchmark: CPU

| Detail | Decision |
|---|---|
| **Tool** | `sysbench` (free, open source, one-liner install) |
| **Command** | `sysbench cpu --cpu-max-prime=20000 --threads=1 run` |
| **Metric** | Events per second (higher = faster) |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation |
| **Additional data** | Processor model, vCPU count, total RAM, system load average |

## Benchmark: Memory

| Detail | Decision |
|---|---|
| **Tool** | `sysbench` (same as CPU — single install) |
| **Command** | `sysbench memory --memory-block-size=1K --memory-total-size=10G --threads=1 run` |
| **Metric** | MiB/sec (higher = faster) |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation |

## Benchmark: Disk I/O

| Detail | Decision |
|---|---|
| **Tool** | `fio` (industry-standard storage benchmark) |
| **Sub-tests** | Sequential read (MB/s), sequential write (MB/s), random read (IOPS), random write (IOPS) |
| **Composite** | Geometric mean of all 4 sub-test scores |
| **Runtime** | 5 seconds per sub-test per iteration (default) |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation (per sub-test and composite) |
| **Notes** | Direct I/O on Linux (`--direct=1`), buffered on macOS. Uses `psync` ioengine. |

## Benchmark: Compile

| Detail | Decision |
|---|---|
| **Tool** | `make` (builds Redis 7.2.7 from source) |
| **Command** | `make -j<cores>` (cgroups-aware core detection) |
| **Metric** | Wall-clock seconds (lower = faster) |
| **Iterations** | 5 measured builds per invocation |
| **Statistics** | Median, min, max, standard deviation |
| **Notes** | Downloads tarball once, re-extracts for each iteration. Tests real-world multi-core throughput. |

## Benchmark: Network

| Detail | Decision |
|---|---|
| **Tool** | `curl` (universally available, no server dependency) |
| **Sub-tests** | Download throughput (MB/s), latency / TTFB (ms) |
| **Composite** | Download throughput (the primary metric for CI pipeline speed) |
| **Endpoint** | Cloudflare speed-test CDN (globally distributed), with Hetzner fallback |
| **Download size** | 25 MiB (26214400 bytes) — large enough to saturate the pipe, small enough to finish quickly |
| **Iterations** | 5 measured runs per invocation |
| **Statistics** | Median, min, max, standard deviation (for both throughput and latency) |
| **Override** | Set `CI_BENCH_NETWORK_URL` for runners with restricted egress or private endpoints |

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

Each Linux resource class is benchmarked on **both** Docker and machine (VM) executors. This isolates how much overhead the Docker container layer adds vs a dedicated VM on the same hardware. Runner names use a `machine.` prefix to distinguish VM results from Docker results in the same resource class.

#### Docker Executor (`cimg/base:current`)

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Trigger |
|---|---|---|---|---|---|
| `medium` | `medium` | x64 | 2 | 4 GB | API trigger with `run_benchmark: true` |
| `large` | `large` | x64 | 4 | 8 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `xlarge` | `xlarge` | x64 | 8 | 16 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `arm.medium` | `arm.medium` | arm64 | 2 | 4 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `arm.large` | `arm.large` | arm64 | 4 | 8 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |

#### Machine Executor (`ubuntu-2404:current`)

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Trigger |
|---|---|---|---|---|---|
| `machine.medium` | `medium` | x64 | 2 | 7.5 GB | API trigger with `run_benchmark: true` |
| `machine.large` | `large` | x64 | 4 | 15 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `machine.xlarge` | `xlarge` | x64 | 8 | 32 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `machine.arm.medium` | `arm.medium` | arm64 | 2 | 8 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `machine.arm.large` | `arm.large` | arm64 | 4 | 16 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |

> Machine executors run in a dedicated VM with no container overlay filesystem, no cgroup-imposed vCPU mismatch (Docker's `nproc` reports the host's cores, not the container's limit), and no noisy-neighbor overhead from other containers sharing the same host. They also get more RAM than Docker at the same resource class.

#### macOS Executor

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Trigger |
|---|---|---|---|---|---|
| `m4pro.medium` | `m4pro.medium` | arm64 | 6 | 12 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |
| `m4pro.large` | `m4pro.large` | arm64 | 12 | 24 GB | API trigger with `run_benchmark: true, run_all: true` — paid plan |

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
- **Dashboard**: `docs/index.html` + `docs/data.json` for interactive visualization

All result artifacts live in the **separate `ci-benchmark-results` repository**, not in the benchmarking repo.

## Configuration

- **Source of truth**: `config/benchmarks.yml` (flat key-value format)
- **Env var overrides**: `CI_BENCH_PROVIDER`, `CI_BENCH_RUNNER`, `CI_BENCH_RESULTS_DIR`, `CI_BENCH_CPU_ENABLED`, `CI_BENCH_ITERATIONS`, `CI_BENCH_CPU_MAX_PRIME`, `CI_BENCH_MEMORY_*`, `CI_BENCH_DISK_*`, `CI_BENCH_COMPILE_*`, `CI_BENCH_NETWORK_*`
- **`CI_BENCH_RESULTS_DIR`**: When set, `run.sh` writes results and dashboard data to this directory instead of the benchmarking repo. All CI configs set this to a clone of the `ci-benchmark-results` repo.

## Robustness Features

- **5 iterations** with median gives stable signal resistant to outliers
- **Standard deviation** exposes noisy-neighbor environments
- **System load recording** helps flag anomalous runs after the fact
- **Git push retry with rebase** handles concurrent benchmark runs (against the results repo)
- **Graceful fallbacks** — run.sh works even if cpu.sh fails (inline sysbench fallback)
- **Cross-platform system info** — Linux primary, macOS fallback for local testing

## Future Expansion

- More CI providers: Buildkite, Jenkins, etc.
- More GitHub Actions runners: `windows-latest`, self-hosted runners
- More GitLab runners: self-hosted, GPU-enabled
- Queue time tracking (record job start vs. trigger time)
- Pricing data and value scoring (cost per benchmark score)
- Charts / visualization (SVG generation from JSON data)
- Scheduled runs (cron triggers) for trend tracking
- ARM vs x64 performance comparison analysis