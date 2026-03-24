# CI Benchmarks

Compare CPU performance across CI providers with reproducible, automated benchmarks.

## Quick Start

### GitHub Actions

1. Go to the **Actions** tab in your GitHub repo
2. Select the **"CI Benchmark"** workflow
3. Click **"Run workflow"**
4. Choose a runner (default: `ubuntu-latest`)
5. Results appear in `results/`

### CircleCI

Trigger via API:

    curl -X POST "https://circleci.com/api/v2/project/gh/OWNER/REPO/pipeline" \
      -H "Circle-Token: $CIRCLECI_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"parameters": {"run_benchmark": true}}'

> **Note:** CircleCI requires a user key or deploy key with write access to push results back to the repo.

## How It Works

All CI configs are thin wrappers that call a single script:

1. **CI installs dependencies** (`sysbench`, `jq`)
2. **CI calls `./benchmarks/run.sh`** with env vars identifying the provider
3. **`run.sh` reads config** from `config/benchmarks.yml`
4. **Warmup** — one throwaway iteration to stabilize CPU frequency/caches
5. **Benchmarks execute** — 5 measured iterations (default), collecting median, min, max, and stddev
6. **Results are saved** as JSON to `results/raw/` and a summary is generated at `results/summary.md`
7. **CI commits and pushes** the results back to the repo

## Adding a New CI Provider

1. Create a new CI config file that:
   - Installs `sysbench` and `jq`
   - Runs `./benchmarks/run.sh` with `CI_BENCH_PROVIDER` and `CI_BENCH_RUNNER` env vars
   - Commits and pushes `results/`
2. That's it — no benchmark logic changes needed.

## Configuration

Edit `config/benchmarks.yml` to control which benchmarks run, iteration count, and parameters.

Override per-run via environment variables:

| Variable | Description | Default |
|---|---|---|
| `CI_BENCH_PROVIDER` | Provider name for results labeling | `unknown` |
| `CI_BENCH_RUNNER` | Runner name for results labeling | `default` |
| `CI_BENCH_CPU_ENABLED` | Enable/disable CPU benchmark | `true` |
| `CI_BENCH_ITERATIONS` | Number of measured iterations (CPU) | `5` |
| `CI_BENCH_CPU_MAX_PRIME` | Sysbench cpu-max-prime parameter | `20000` |
| `CI_BENCH_CPU_WARMUP` | Run a warmup iteration before measuring (CPU) | `true` |
| `CI_BENCH_MEMORY_ENABLED` | Enable/disable memory benchmark | `true` |
| `CI_BENCH_MEMORY_ITERATIONS` | Number of measured iterations (memory) | `5` |
| `CI_BENCH_MEMORY_BLOCK_SIZE` | Sysbench memory-block-size parameter | `1K` |
| `CI_BENCH_MEMORY_TOTAL_SIZE` | Sysbench memory-total-size parameter | `10G` |
| `CI_BENCH_MEMORY_WARMUP` | Run a warmup iteration before measuring (memory) | `true` |

## Results

Results are stored in two formats:

- **`results/raw/*.json`** — one file per run, full data including all scores (CPU + memory), system info, and load average
- **`results/summary.md`** — auto-generated leaderboard showing the most recent run per provider/runner, sorted by CPU score, with memory throughput

### Example summary output

| Provider | Runner | CPU Score (median) | CPU Stddev | Memory (median) | Mem Stddev | Processor | vCPUs | RAM |
|---|---|---|---|---|---|---|---|---|
| circleci | medium | 3587.2 events/sec | ±42.10 | 8523.40 MiB/sec | ±120.30 | AMD EPYC 7R13 | 2 | 4096 MB |
| github-actions | ubuntu-latest | 3421.5 events/sec | ±38.50 | 7891.20 MiB/sec | ±95.60 | AMD EPYC 7763 | 2 | 7168 MB |

## Project Structure

    benchmarks/
      run.sh              Main entrypoint script
      lib/cpu.sh          CPU benchmark (sysbench)
      lib/memory.sh       Memory benchmark (sysbench)
    config/
      benchmarks.yml      Benchmark configuration (flat key-value)
    results/
      raw/                JSON results (one per run)
      summary.md          Generated summary table (latest per provider)
    .github/workflows/    GitHub Actions config
    .circleci/            CircleCI config

## License

MIT