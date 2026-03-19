# vLLM Spark Nightly

Automated nightly builds of [vLLM](https://github.com/vllm-project/vllm) wheels for **NVIDIA DGX Spark** (ARM/aarch64, sm_121).

## How it works

A GitHub Actions workflow runs daily at 06:00 UTC:

1. Resolves the latest vLLM `main` commit
2. Skips if that commit was already built (checks rolling release)
3. Builds a `linux_aarch64` wheel targeting `sm_121` (CUDA 13.1, PyTorch 26.01)
4. Publishes a **date-tagged release** (e.g. `vllm-20260318`) and updates the **rolling release** (`prebuilt-vllm-current`)

## Consuming wheels

### From the rolling release (latest)

```bash
# Download the latest wheel
gh release download prebuilt-vllm-current -p "vllm-*.whl"
pip install vllm-*.whl
```

### From a specific date

```bash
gh release download vllm-20260318 -p "vllm-*.whl"
```

### In spark-vllm-docker

Update `WHEELS_REPO` in `build-and-copy.sh`:

```bash
WHEELS_REPO="<org>/vllm-spark-nightly"
```

## Manual builds

Trigger a build via the Actions tab or CLI:

```bash
# Build from main
gh workflow run nightly-build.yml

# Build a specific ref
gh workflow run nightly-build.yml -f vllm_ref=v0.17.0

# Build a specific commit
gh workflow run nightly-build.yml -f vllm_ref=abc123def
```

## Patch management

`patches.json` controls PR reverts/applies against the vLLM source before building:

```json
{
  "reverts": [
    {"pr": 34758, "reason": "Unguarded Hopper code breaks sm_121 build"}
  ],
  "applies": []
}
```

Patches are non-fatal — if a revert/apply fails (e.g. the PR was already reverted upstream), the build continues. The release notes document which patches were applied.

## Benchmark archival

Scripts in `scripts/` archive benchmark results, container logs, and wheels to `~/benchmarks/` for tracking performance over time.

### Full nightly workflow

```bash
# 1. Download the latest nightly wheel into spark-vllm-docker
cd ~/git/spark-vllm-docker
gh release download prebuilt-vllm-current --repo <org>/vllm-spark-nightly -p "vllm-*.whl" -D wheels/
# Or point WHEELS_REPO in build-and-copy.sh to vllm-spark-nightly

# 2. Build the container image and launch
./build-and-copy.sh
./run-recipe.sh nemotron-3-super-nvfp4 --solo -d

# 3. Benchmark and archive in one step
~/git/vllm-spark-nightly/scripts/bench-and-archive.sh

# 4. Compare with the previous run
~/git/vllm-spark-nightly/scripts/compare-runs.sh <previous_run_id> latest
```

`bench-and-archive.sh` runs llama-benchy, then immediately archives the results, container log, and wheel. Pass `--` to forward extra args to llama-benchy (e.g. `-- --concurrency 1 2 4`).

To investigate a regression:
```bash
# Read the container log from the bad run
zstd -d ~/benchmarks/runs/<run_id>/container.log.zst -c | less

# Restore its exact wheel and re-test
~/git/vllm-spark-nightly/scripts/replay-wheel.sh <run_id>
```

### Archive a run

```bash
scripts/archive-benchmark.sh ~/git/llama-benchy/results.json
```

This captures the results JSON, container log (compressed with zstd), and the wheel used for the run. Wheels are deduplicated by filename.

Options: `--host`, `--container`, `--wheel-dir`, `--recipe`, `--no-wheel`, `--no-log`, `--notes`, `--dry-run`. Run with `--help` for details.

### List archived runs

```bash
scripts/list-benchmarks.sh
```

### Compare runs

```bash
scripts/compare-runs.sh 20260318_214500 20260319_013102
scripts/compare-runs.sh 20260318_214500 latest
```

Wraps `llama-benchy/scripts/compare.py` with auto-generated labels from metadata.

### Replay a wheel

```bash
scripts/replay-wheel.sh 20260319_013102
```

Copies the archived wheel back to `spark-vllm-docker/wheels/` and prints the recipe launch command.

### Archive layout

```
~/benchmarks/
  index.json                        # Catalog of all runs
  latest -> runs/20260319_013102    # Symlink to most recent
  runs/<run_id>/
    metadata.json                   # Full context
    results.json                    # llama-benchy output
    container.log.zst               # Compressed container log
  wheels/                           # Deduplicated wheel store
```

## Build details

- **Base image:** `nvcr.io/nvidia/pytorch:26.01-py3`
- **Target arch:** `TORCH_CUDA_ARCH_LIST=12.1a` (sm_121)
- **Runner:** `linux-arm64-16core` (GitHub-hosted ARM runner)
- **Cache:** Docker BuildKit GHA cache for incremental builds
