# CI Benchmarks

Compare CPU, memory, disk, compile, and network performance across CI providers and runner types with reproducible, automated benchmarks.

## Quick Start

### GitHub Actions

#### Single Runner (default)

1. Go to the **Actions** tab in your GitHub repo
2. Select the **"CI Benchmark"** workflow
3. Click **"Run workflow"**
4. Choose a runner (default: `ubuntu-latest`)
5. Results appear in `results/`

#### All Runners (matrix mode)

1. Go to the **Actions** tab in your GitHub repo
2. Select the **"CI Benchmark"** workflow
3. Click **"Run workflow"**
4. Check the **"Run benchmarks across all runner types"** checkbox
5. This launches benchmarks in parallel across all supported runners

### CircleCI

#### Medium only (default)

```
curl -X POST "https://circleci.com/api/v2/project/gh/OWNER/REPO/pipeline" \
  -H "Circle-Token: $CIRCLECI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"parameters": {"run_benchmark": true}}'
```

#### All resource classes

```
curl -X POST "https://circleci.com/api/v2/project/gh/OWNER/REPO/pipeline" \
  -H "Circle-Token: $CIRCLECI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"parameters": {"run_benchmark": true, "run_all": true}}'
```

> **Note:** CircleCI requires a `RESULTS_REPO_TOKEN` environment variable with push access to the results repository.

### GitLab CI

> GitLab is used as a CI runner only — GitHub remains the VCS. A [sync workflow](.github/workflows/sync-gitlab.yml) pushes `main` to GitLab automatically.

#### Small runner only (default)

Trigger via GitLab UI: **Build → Pipelines → Run pipeline**

Or via API:

    curl -X POST "https://gitlab.com/api/v4/projects/${PROJECT_ID}/trigger/pipeline" \
      -F "token=${TRIGGER_TOKEN}" \
      -F "ref=main"

#### All runner sizes

Trigger via GitLab UI: **Build → Pipelines → Run pipeline**, set variable `RUN_ALL` = `true`

Or via API:

    curl -X POST "https://gitlab.com/api/v4/projects/${PROJECT_ID}/trigger/pipeline" \
      -F "token=${TRIGGER_TOKEN}" \
      -F "ref=main" \
      -F "variables[RUN_ALL]=true"

> **Note:** GitLab requires a `RESULTS_REPO_TOKEN` CI/CD variable with push access to the results repository. Larger runners and ARM runners require a GitLab Premium or Ultimate plan.

## Supported Runners

### GitHub Actions

| Runner | OS | Architecture | vCPUs | Notes |
|--------|----|--------------|-------|-------|
| `ubuntu-latest` | Ubuntu (latest LTS) | x64 | 2 | Default free-tier runner |
| `ubuntu-24.04` | Ubuntu 24.04 | x64 | 2 | Pinned OS version |
| `ubuntu-22.04` | Ubuntu 22.04 | x64 | 2 | Pinned OS version |
| `ubuntu-latest-4-cores` | Ubuntu (latest LTS) | x64 | 4 | Larger runner (paid) |
| `ubuntu-latest-8-cores` | Ubuntu (latest LTS) | x64 | 8 | Larger runner (paid) |
| `ubuntu-latest-16-cores` | Ubuntu (latest LTS) | x64 | 16 | Larger runner (paid) |
| `macos-latest` | macOS (latest) | arm64 | 3+ | Apple Silicon runner |
| `macos-13` | macOS 13 (Ventura) | x64 | 3+ | Intel-based runner |

> **Note:** The larger Ubuntu runners (`*-N-cores`) require a GitHub Team or Enterprise plan. If your plan doesn't include them, those matrix jobs will fail gracefully.

### CircleCI

Each Linux resource class is benchmarked on **both** executor types to measure Docker container overhead vs bare-metal VM performance.

#### Docker Executor (`cimg/base:current`)

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Notes |
|-------------|----------------|--------------|-------|-----|-------|
| `medium` | `medium` | x64 | 2 | 4 GB | Default (free-tier eligible) |
| `large` | `large` | x64 | 4 | 8 GB | Paid resource class |
| `xlarge` | `xlarge` | x64 | 8 | 16 GB | Paid resource class |
| `arm.medium` | `arm.medium` | arm64 | 2 | 4 GB | ARM-based runner |
| `arm.large` | `arm.large` | arm64 | 4 | 8 GB | ARM-based runner |

#### Machine Executor (`ubuntu-2404:current`)

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Notes |
|-------------|----------------|--------------|-------|-----|-------|
| `machine.medium` | `medium` | x64 | 2 | 7.5 GB | Dedicated VM — no container overhead |
| `machine.large` | `large` | x64 | 4 | 15 GB | Dedicated VM — no container overhead |
| `machine.xlarge` | `xlarge` | x64 | 8 | 32 GB | Dedicated VM — no container overhead |
| `machine.arm.medium` | `arm.medium` | arm64 | 2 | 8 GB | Dedicated ARM VM |
| `machine.arm.large` | `arm.large` | arm64 | 4 | 16 GB | Dedicated ARM VM |

#### macOS Executor

| Runner Name | Resource Class | Architecture | vCPUs | RAM | Notes |
|-------------|----------------|--------------|-------|-----|-------|
| `m4pro.medium` | `m4pro.medium` | arm64 | 6 | 12 GB | Apple Silicon (M4 Pro) |
| `m4pro.large` | `m4pro.large` | arm64 | 12 | 24 GB | Apple Silicon (M4 Pro) |

> **Note:** Larger resource classes, ARM runners, and macOS runners require a CircleCI paid plan. Machine executors get more RAM than Docker executors at the same resource class because there is no container overhead. The `machine.*` runner names in results distinguish VM jobs from Docker jobs on the same resource class.

### GitLab CI

| Runner Tag | Architecture | vCPUs | Notes |
|------------|--------------|-------|-------|
| `small-amd64` | x64 | 2 | Default (free-tier eligible) |
| `medium-amd64` | x64 | 4 | Paid runner |
| `large-amd64` | x64 | 8 | Paid runner |
| `medium-arm64` | arm64 | 4 | Paid runner |
| `large-arm64` | arm64 | 8 | Paid runner |

> **Note:** Larger runners and ARM runners require a GitLab Premium or Ultimate plan. GitLab SaaS free tier includes 400 CI/CD minutes/month.

## How It Works

All CI configs are thin wrappers that call a single script:

1. **CI installs dependencies** (`sysbench`, `jq`, `fio`, `build-essential`)
2. **CI calls `./benchmarks/run.sh`** with env vars identifying the provider
3. **`run.sh` reads config** from `config/benchmarks.yml`
4. **Benchmarks execute** — CPU, memory, disk I/O, compile, and network — 5 measured iterations (default), collecting median, min, max, and stddev
6. **Results are saved** as JSON to `results/raw/` and a summary is generated at `results/summary.md` in the **results repository**
7. **CI commits and pushes** the results to a separate `ci-benchmark-results` repository

## Adding a New CI Provider

1. Create a new CI config file that:
   - Installs `sysbench`, `jq`, `fio`, and `build-essential` (or platform equivalents)
   - Runs `./benchmarks/run.sh` with `CI_BENCH_PROVIDER` and `CI_BENCH_RUNNER` env vars
   - Clones the results repo, sets `CI_BENCH_RESULTS_DIR`, and pushes results to it
2. That's it — no benchmark logic changes needed.

## Configuration

Edit `config/benchmarks.yml` to control which benchmarks run, iteration count, and parameters.

Override per-run via environment variables:

| Variable | Description | Default |
|---|---|---|
| `CI_BENCH_PROVIDER` | Provider name for results labeling | `unknown` |
| `CI_BENCH_RUNNER` | Runner name for results labeling | `default` |
| `CI_BENCH_RESULTS_DIR` | Path to external results repository clone | (writes to benchmarking repo) |
| `CI_BENCH_CPU_ENABLED` | Enable/disable CPU benchmark | `true` |
| `CI_BENCH_ITERATIONS` | Number of measured iterations (CPU) | `5` |
| `CI_BENCH_CPU_MAX_PRIME` | Sysbench cpu-max-prime parameter | `20000` |
| `CI_BENCH_MEMORY_ENABLED` | Enable/disable memory benchmark | `true` |
| `CI_BENCH_MEMORY_ITERATIONS` | Number of measured iterations (memory) | `5` |
| `CI_BENCH_MEMORY_BLOCK_SIZE` | Sysbench memory-block-size parameter | `1K` |
| `CI_BENCH_MEMORY_TOTAL_SIZE` | Sysbench memory-total-size parameter | `10G` |
| `CI_BENCH_DISK_ENABLED` | Enable/disable disk I/O benchmark | `true` |
| `CI_BENCH_DISK_ITERATIONS` | Number of measured iterations (disk) | `5` |
| `CI_BENCH_DISK_RUNTIME` | Runtime in seconds per fio sub-test | `5` |
| `CI_BENCH_COMPILE_ENABLED` | Enable/disable compile benchmark | `true` |
| `CI_BENCH_COMPILE_ITERATIONS` | Number of measured builds (compile) | `5` |
| `CI_BENCH_NETWORK_ENABLED` | Enable/disable network benchmark | `true` |
| `CI_BENCH_NETWORK_ITERATIONS` | Number of measured iterations (network) | `5` |
| `CI_BENCH_NETWORK_DOWNLOAD_BYTES` | Size of the test download in bytes | `26214400` (25 MiB) |
| `CI_BENCH_NETWORK_URL` | Override the download test URL (for restricted egress) | (auto-detected) |

## Results Repository Setup

Benchmark results are stored in a separate GitHub repository to keep this repo focused on benchmark logic and CI configuration.

### Setup

1. Create a new GitHub repository named `ci-benchmark-results` (under the same owner)
2. Initialize it with a `results/raw/` directory and copy `docs/index.html` from this repo
3. Create a GitHub Personal Access Token (PAT) with `repo` scope (or fine-grained with push access to the results repo)
4. Add the token as a secret in each CI provider:
   - **GitHub Actions**: Add `RESULTS_REPO_TOKEN` as a repository secret
   - **CircleCI**: Add `RESULTS_REPO_TOKEN` as an environment variable
   - **GitLab CI**: Add `RESULTS_REPO_TOKEN` as a CI/CD variable (masked & protected)

The results repo name defaults to `{owner}/ci-benchmark-results` but can be overridden via CI environment variables.

## Workflow Trigger Reference

### GitHub Actions

| Trigger | Behavior |
|---------|----------|
| Push to `main` | Runs a single benchmark on `ubuntu-latest` |
| `workflow_dispatch` (default) | Runs a single benchmark on the chosen runner |
| `workflow_dispatch` with `run_matrix: true` | Runs benchmarks across all 8 runner types in parallel |

### CircleCI

| Parameters | Behavior |
|------------|----------|
| `run_benchmark: true` | Runs a benchmark on `medium` (Docker + machine) |
| `run_benchmark: true, run_all: true` | Runs benchmarks across all 12 executor/resource-class combinations in parallel (5 Docker + 5 machine + 2 macOS) |

### GitLab CI

| Trigger | Behavior |
|---------|----------|
| GitLab UI / API (default) | Runs a single benchmark on `small-amd64` |
| GitLab UI / API with `RUN_ALL=true` | Runs benchmarks across all 5 runner sizes in parallel |

## Results

Results are stored in a **separate repository** (`ci-benchmark-results`) in two formats:

- **`results/raw/*.json`** — one file per run, full data including all scores (CPU, memory, disk, compile, network), system info, and load average
- **`results/summary.md`** — auto-generated leaderboard showing the most recent run per provider/runner, sorted by CPU score, with memory, disk, and network throughput

The dashboard (`docs/index.html` and `docs/data.json`) also lives in the results repository.

### Example summary output

| Provider | Runner | CPU Score (median) | CPU Stddev | Memory (median) | Mem Stddev | Disk (composite) | Disk Stddev | Network (median) | Net Stddev | Processor | vCPUs | RAM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| github-actions | ubuntu-latest-16-cores | 5842.1 events/sec | ±25.30 | 12450.80 MiB/sec | ±85.10 | 1245.30 | ±42.10 | 285.40 MB/s | ±18.20 | AMD EPYC 7R13 | 16 | 65536 MB |
| github-actions | ubuntu-latest-8-cores | 4921.3 events/sec | ±31.40 | 10230.50 MiB/sec | ±92.40 | 1180.50 | ±38.70 | 272.10 MB/s | ±22.50 | AMD EPYC 7R13 | 8 | 32768 MB |
| circleci | xlarge | 4215.8 events/sec | ±35.20 | 9845.60 MiB/sec | ±105.70 | 980.20 | ±55.30 | 195.30 MB/s | ±15.80 | AMD EPYC 7R13 | 8 | 16384 MB |
| circleci | large | 3812.4 events/sec | ±39.80 | 9120.30 MiB/sec | ±110.20 | 920.40 | ±48.90 | 188.70 MB/s | ±19.40 | AMD EPYC 7R13 | 4 | 8192 MB |
| circleci | medium | 3587.2 events/sec | ±42.10 | 8523.40 MiB/sec | ±120.30 | 850.10 | ±52.60 | 175.20 MB/s | ±21.30 | AMD EPYC 7R13 | 2 | 4096 MB |
| github-actions | ubuntu-latest | 3421.5 events/sec | ±38.50 | 7891.20 MiB/sec | ±95.60 | 1050.80 | ±45.20 | 310.50 MB/s | ±25.70 | AMD EPYC 7763 | 2 | 7168 MB |
| github-actions | macos-latest | 3105.7 events/sec | ±28.90 | 11520.10 MiB/sec | ±78.30 | 1320.60 | ±35.40 | 245.80 MB/s | ±12.90 | Apple M1 | 3 | 7168 MB |
| gitlab | small-amd64 | 3350.4 events/sec | ±36.70 | 7950.60 MiB/sec | ±88.40 | 890.30 | ±50.10 | 160.40 MB/s | ±18.60 | AMD EPYC 7B13 | 2 | 8192 MB |

## Project Structure

    benchmarks/
      run.sh              Main entrypoint script
      lib/cpu.sh          CPU benchmark (sysbench)
      lib/memory.sh       Memory benchmark (sysbench)
      lib/disk.sh         Disk I/O benchmark (fio)
      lib/compile.sh      Compile benchmark (Redis build)
      lib/network.sh      Network benchmark (curl download + TTFB)
    config/
      benchmarks.yml      Benchmark configuration (flat key-value)
    .github/workflows/    GitHub Actions config
      benchmark.yml         Single + matrix runner workflows
      sync-gitlab.yml       Pushes main to GitLab mirror
    .circleci/            CircleCI config
      config.yml            Multi-resource-class workflows
    .gitlab-ci.yml          GitLab CI config (5 runner sizes)

    ## Results repository (ci-benchmark-results)
    results/
      raw/                JSON results (one per run)
      summary.md          Generated summary table (latest per provider)
    docs/
      index.html          Dashboard UI
      data.json           Consolidated results for dashboard

## License

MIT