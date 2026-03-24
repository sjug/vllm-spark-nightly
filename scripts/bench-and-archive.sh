#!/bin/bash
# bench-and-archive.sh — Run llama-benchy against a running vLLM instance, then archive results.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
HOST="sparky"
PORT="8000"
CONTAINER="vllm_node"
PP="128 256 512 1024 2048"
TG="32 64 128"
DEPTHS="0 4096 8192 16384 32768"
RUNS=3
ARCHIVE_DIR="$HOME/benchmarks"
WHEEL_DIR="$HOME/git/spark-vllm-docker/wheels"
RECIPE=""
NOTES=""
NO_WHEEL=false
NO_LOG=false
CONTAINER_RT=""
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
Usage: bench-and-archive.sh [options] [-- extra-llama-benchy-args]

Run llama-benchy against a serving endpoint and archive the results.

Options:
  --host <hostname>       Host running vLLM (default: sparky)
  --port <port>           vLLM port (default: 8000)
  --container <name>      Container name for log capture (default: vllm_node)
  --pp <sizes>            Prompt sizes, space-separated (default: "128 256 512 1024 2048")
  --tg <sizes>            Token gen sizes, space-separated (default: "32 64 128")
  --depth <sizes>         Context depths, space-separated (default: "0 4096 8192 16384 32768")
  --runs <n>              Runs per test (default: 3)
  --recipe <name>         Recipe name (default: auto-detect from model)
  --wheel-dir <path>      Where to find the .whl (default: ~/git/spark-vllm-docker/wheels/)
  --archive-dir <path>    Archive root (default: ~/benchmarks)
  --no-wheel              Skip archiving the wheel
  --no-log                Skip container log capture
  --container-runtime <rt> Container runtime: podman or docker (default: auto-detect)
  --notes <text>          Free-text notes
  -h, --help              Show this help

Extra arguments after -- are passed directly to llama-benchy.

Example:
  bench-and-archive.sh
  bench-and-archive.sh --host sparky --recipe nemotron-3-super-nvfp4
  bench-and-archive.sh -- --no-warmup --concurrency 1 2 4
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2"; shift 2 ;;
        --port)        PORT="$2"; shift 2 ;;
        --container)   CONTAINER="$2"; shift 2 ;;
        --pp)          PP="$2"; shift 2 ;;
        --tg)          TG="$2"; shift 2 ;;
        --depth)       DEPTHS="$2"; shift 2 ;;
        --runs)        RUNS="$2"; shift 2 ;;
        --recipe)      RECIPE="$2"; shift 2 ;;
        --wheel-dir)   WHEEL_DIR="$2"; shift 2 ;;
        --archive-dir) ARCHIVE_DIR="$2"; shift 2 ;;
        --no-wheel)    NO_WHEEL=true; shift ;;
        --no-log)      NO_LOG=true; shift ;;
        --container-runtime) CONTAINER_RT="$2"; shift 2 ;;
        --notes)       NOTES="$2"; shift 2 ;;
        -h|--help)     usage ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
RESULTS_FILE="/tmp/bench_${TIMESTAMP}.json"

echo "=== Running benchmark against $HOST:$PORT ==="
echo "  PP:     $PP"
echo "  TG:     $TG"
echo "  Depths: $DEPTHS"
echo "  Runs:   $RUNS"
echo "  Output: $RESULTS_FILE"
echo ""

# Activate llama-benchy venv if not already on PATH
if ! command -v llama-benchy &>/dev/null; then
    LLAMA_BENCHY_VENV="$HOME/git/llama-benchy/.venv/bin/activate"
    if [[ -f "$LLAMA_BENCHY_VENV" ]]; then
        source "$LLAMA_BENCHY_VENV"
    else
        echo "Error: llama-benchy not found. Install it or activate its venv." >&2
        exit 1
    fi
fi

# Run llama-benchy
llama-benchy \
    --base-url "http://${HOST}:${PORT}/v1" \
    --pp $PP \
    --tg $TG \
    --depth $DEPTHS \
    --runs "$RUNS" \
    --format json \
    --save-result "$RESULTS_FILE" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

echo ""
echo "=== Benchmark complete, archiving ==="
echo ""

# Build archive args
ARCHIVE_ARGS=(
    "$RESULTS_FILE"
    --host "$HOST"
    --container "$CONTAINER"
    --wheel-dir "$WHEEL_DIR"
    --archive-dir "$ARCHIVE_DIR"
)
[[ -n "$RECIPE" ]] && ARCHIVE_ARGS+=(--recipe "$RECIPE")
[[ -n "$NOTES" ]] && ARCHIVE_ARGS+=(--notes "$NOTES")
[[ "$NO_WHEEL" == "true" ]] && ARCHIVE_ARGS+=(--no-wheel)
[[ "$NO_LOG" == "true" ]] && ARCHIVE_ARGS+=(--no-log)
[[ -n "$CONTAINER_RT" ]] && ARCHIVE_ARGS+=(--container-runtime "$CONTAINER_RT")

"$SCRIPT_DIR/archive-benchmark.sh" "${ARCHIVE_ARGS[@]}"

# Clean up temp file
rm -f "$RESULTS_FILE"
