#!/bin/bash
# archive-benchmark.sh — Archive benchmark results, container logs, and wheels.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NIGHTLY_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
HOST="sparky"
CONTAINER="vllm_node"
WHEEL_DIR="$HOME/git/spark-vllm-docker/wheels"
RECIPE=""
ARCHIVE_DIR="$HOME/benchmarks"
ARCHIVE_WHEEL=true
CAPTURE_LOG=true
NOTES=""
DRY_RUN=false
RESULTS_FILE=""

usage() {
    cat <<'EOF'
Usage: archive-benchmark.sh <results.json> [options]

Archive a benchmark run with its results, container log, and wheel.

Options:
  --host <hostname>       Host running the container (default: sparky)
  --container <name>      Container name for log capture (default: vllm_node)
  --wheel-dir <path>      Where to find the .whl (default: ~/git/spark-vllm-docker/wheels/)
  --recipe <name>         Recipe name (default: auto-detect from model in results JSON)
  --archive-dir <path>    Archive root (default: ~/benchmarks)
  --no-wheel              Skip archiving the wheel (metadata only)
  --no-log                Skip container log capture
  --notes <text>          Free-text notes
  --dry-run               Show what would be archived
  -h, --help              Show this help
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2"; shift 2 ;;
        --container)   CONTAINER="$2"; shift 2 ;;
        --wheel-dir)   WHEEL_DIR="$2"; shift 2 ;;
        --recipe)      RECIPE="$2"; shift 2 ;;
        --archive-dir) ARCHIVE_DIR="$2"; shift 2 ;;
        --no-wheel)    ARCHIVE_WHEEL=false; shift ;;
        --no-log)      CAPTURE_LOG=false; shift ;;
        --notes)       NOTES="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$RESULTS_FILE" ]]; then
                RESULTS_FILE="$1"
            else
                echo "Unexpected argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$RESULTS_FILE" ]]; then
    echo "Error: results.json file required" >&2
    echo "Usage: archive-benchmark.sh <results.json> [options]" >&2
    exit 1
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
    echo "Error: results file not found: $RESULTS_FILE" >&2
    exit 1
fi

# Generate run ID from UTC timestamp
RUN_ID="$(date -u +%Y%m%d_%H%M%S)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_DIR="$ARCHIVE_DIR/runs/$RUN_ID"

# Parse benchmark metadata from results JSON
read -r TOOL_VERSION MODEL < <(python3 -c "
import json, sys
d = json.load(open('$RESULTS_FILE'))
print(d.get('version', 'unknown'), d.get('model', 'unknown'))
")

# Extract benchmark parameters
BENCH_PARAMS=$(python3 -c "
import json
d = json.load(open('$RESULTS_FILE'))
benchmarks = d.get('benchmarks', [])
pp = sorted(set(b['prompt_size'] for b in benchmarks))
tg = sorted(set(b['response_size'] for b in benchmarks))
depth = sorted(set(b['context_size'] for b in benchmarks))
print(json.dumps(pp))
print(json.dumps(tg))
print(json.dumps(depth))
print(len(benchmarks))
")
PP_JSON=$(echo "$BENCH_PARAMS" | sed -n '1p')
TG_JSON=$(echo "$BENCH_PARAMS" | sed -n '2p')
DEPTH_JSON=$(echo "$BENCH_PARAMS" | sed -n '3p')
BENCH_COUNT=$(echo "$BENCH_PARAMS" | sed -n '4p')

# Auto-detect recipe from model name
RECIPE_DIR="$HOME/git/spark-vllm-docker/recipes"
if [[ -z "$RECIPE" && -d "$RECIPE_DIR" ]]; then
    RECIPE=$(python3 -c "
import yaml, glob, sys
model = '$MODEL'
for f in sorted(glob.glob('$RECIPE_DIR/*.yaml')):
    with open(f) as fh:
        r = yaml.safe_load(fh)
    if r.get('model') == model:
        # Recipe name is the filename without extension
        print(f.rsplit('/', 1)[-1].rsplit('.', 1)[0])
        sys.exit(0)
print('')
" 2>/dev/null || echo "")
fi

if [[ -z "$RECIPE" ]]; then
    echo "Warning: could not auto-detect recipe for model '$MODEL'" >&2
fi

# Find wheel
WHEEL_FILE=""
WHEEL_FILENAME=""
WHEEL_VERSION=""
WHEEL_COMMIT=""
WHEEL_SHA256=""
if [[ "$ARCHIVE_WHEEL" == "true" ]]; then
    # Find the most recent .whl file
    WHEEL_FILE=$(find "$WHEEL_DIR" -maxdepth 1 -name "vllm-*.whl" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2)
    if [[ -n "$WHEEL_FILE" ]]; then
        WHEEL_FILENAME="$(basename "$WHEEL_FILE")"
        # Extract version from wheel filename: vllm-<version>-<rest>.whl
        WHEEL_VERSION=$(echo "$WHEEL_FILENAME" | sed 's/^vllm-//; s/-cp[0-9].*$//')
        # Extract vllm commit from version string (g<hash> pattern)
        WHEEL_COMMIT=$(echo "$WHEEL_VERSION" | grep -oP '(?<=\+g)[0-9a-f]+' | head -1 || echo "")
        WHEEL_SHA256=$(sha256sum "$WHEEL_FILE" | cut -d' ' -f1)
    else
        echo "Warning: no wheel found in $WHEEL_DIR" >&2
        ARCHIVE_WHEEL=false
    fi
fi

# Read patches.json
PATCHES_JSON="{}"
if [[ -f "$NIGHTLY_REPO/patches.json" ]]; then
    PATCHES_JSON=$(cat "$NIGHTLY_REPO/patches.json")
fi

# Dry run — show what would happen
if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== DRY RUN ==="
    echo "Run ID:     $RUN_ID"
    echo "Timestamp:  $TIMESTAMP"
    echo "Results:    $RESULTS_FILE"
    echo "Model:      $MODEL"
    echo "Recipe:     ${RECIPE:-<none>}"
    echo "Host:       $HOST"
    echo "Container:  $CONTAINER"
    echo "Archive:    $RUN_DIR/"
    echo "Benchmarks: $BENCH_COUNT configs"
    echo "PP sizes:   $PP_JSON"
    echo "TG sizes:   $TG_JSON"
    echo "Depths:     $DEPTH_JSON"
    if [[ "$ARCHIVE_WHEEL" == "true" ]]; then
        echo "Wheel:      $WHEEL_FILENAME ($WHEEL_SHA256)"
    else
        echo "Wheel:      (skipped)"
    fi
    if [[ "$CAPTURE_LOG" == "true" ]]; then
        echo "Log:        will capture from $HOST:$CONTAINER"
    else
        echo "Log:        (skipped)"
    fi
    echo "Notes:      ${NOTES:-<none>}"
    exit 0
fi

# Create directories
mkdir -p "$RUN_DIR"
mkdir -p "$ARCHIVE_DIR/wheels"

echo "Archiving benchmark run $RUN_ID..."

# 1. Copy results
cp "$RESULTS_FILE" "$RUN_DIR/results.json"
echo "  Copied results.json"

# 2. Capture container log
if [[ "$CAPTURE_LOG" == "true" ]]; then
    if ssh -o ConnectTimeout=5 "$HOST" "docker logs $CONTAINER" > /dev/null 2>&1; then
        ssh "$HOST" "docker logs $CONTAINER 2>&1" | zstd -3 -q > "$RUN_DIR/container.log.zst"
        echo "  Captured container log ($(du -h "$RUN_DIR/container.log.zst" | cut -f1))"
    else
        echo "  Warning: could not capture container log from $HOST:$CONTAINER" >&2
    fi
fi

# 3. Archive wheel (deduplicated)
if [[ "$ARCHIVE_WHEEL" == "true" ]]; then
    WHEEL_STORE="$ARCHIVE_DIR/wheels/$WHEEL_FILENAME"
    if [[ ! -f "$WHEEL_STORE" ]]; then
        cp "$WHEEL_FILE" "$WHEEL_STORE"
        echo "  Stored wheel: $WHEEL_FILENAME"
    else
        echo "  Wheel already archived: $WHEEL_FILENAME"
    fi
    # Hard-link into run directory
    ln "$WHEEL_STORE" "$RUN_DIR/$WHEEL_FILENAME" 2>/dev/null || cp "$WHEEL_STORE" "$RUN_DIR/$WHEEL_FILENAME"
fi

# 4. Write metadata.json
python3 -c "
import json, sys

metadata = {
    'archive_version': 1,
    'run_id': '$RUN_ID',
    'timestamp': '$TIMESTAMP',
    'wheel': {
        'filename': '${WHEEL_FILENAME}',
        'version': '${WHEEL_VERSION}',
        'vllm_commit': '${WHEEL_COMMIT}',
        'sha256': '${WHEEL_SHA256}'
    } if '${ARCHIVE_WHEEL}' == 'true' else None,
    'recipe': {
        'name': '${RECIPE}',
        'model': '${MODEL}'
    },
    'benchmark': {
        'tool_version': '${TOOL_VERSION}',
        'pp': ${PP_JSON},
        'tg': ${TG_JSON},
        'depth': ${DEPTH_JSON},
        'configs': ${BENCH_COUNT}
    },
    'host': '${HOST}',
    'patches': ${PATCHES_JSON},
    'notes': '''${NOTES}'''
}
with open('$RUN_DIR/metadata.json', 'w') as f:
    json.dump(metadata, f, indent=2)
    f.write('\n')
" || { echo "Error writing metadata.json" >&2; exit 1; }
echo "  Wrote metadata.json"

# 5. Append to index.json
INDEX_FILE="$ARCHIVE_DIR/index.json"
python3 -c "
import json, os

index_file = '$INDEX_FILE'
entry = {
    'run_id': '$RUN_ID',
    'timestamp': '$TIMESTAMP',
    'model': '${MODEL}',
    'recipe': '${RECIPE}',
    'vllm_version': '${WHEEL_VERSION}',
    'wheel_filename': '${WHEEL_FILENAME}',
    'host': '${HOST}',
    'notes': '''${NOTES}'''
}

if os.path.exists(index_file):
    with open(index_file) as f:
        index = json.load(f)
else:
    index = []

index.append(entry)
with open(index_file, 'w') as f:
    json.dump(index, f, indent=2)
    f.write('\n')
"
echo "  Updated index.json"

# 6. Update latest symlink
ln -sfn "runs/$RUN_ID" "$ARCHIVE_DIR/latest"
echo "  Updated latest -> runs/$RUN_ID"

# Summary
echo ""
echo "=== Archive Complete ==="
echo "  Run:      $RUN_ID"
echo "  Location: $RUN_DIR/"
echo "  Model:    $MODEL"
echo "  Recipe:   ${RECIPE:-<none>}"
if [[ "$ARCHIVE_WHEEL" == "true" ]]; then
    echo "  Wheel:    $WHEEL_FILENAME"
fi
echo ""
echo "To compare with a future run:"
echo "  $(dirname "$0")/compare-runs.sh $RUN_ID <other_run_id>"
echo ""
echo "To list all archived runs:"
echo "  $(dirname "$0")/list-benchmarks.sh"
