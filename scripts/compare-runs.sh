#!/bin/bash
# compare-runs.sh — Compare archived benchmark runs using llama-benchy's compare.py.
set -euo pipefail

ARCHIVE_DIR="$HOME/benchmarks"
COMPARE_SCRIPT="$HOME/git/llama-benchy/scripts/compare.py"

usage() {
    cat <<'EOF'
Usage: compare-runs.sh <run_id> [run_id...]

Compare archived benchmark runs. Generates labels from metadata automatically.

  "latest" is an alias for the most recent run.

Examples:
  compare-runs.sh 20260318_214500 20260319_013102
  compare-runs.sh 20260318_214500 latest
  compare-runs.sh latest              # Show single run results
EOF
    exit 0
}

if [[ $# -lt 1 ]]; then
    usage
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

if [[ ! -f "$COMPARE_SCRIPT" ]]; then
    echo "Error: compare.py not found at $COMPARE_SCRIPT" >&2
    exit 1
fi

# Resolve run IDs and build labels/paths
LABELS=()
FILES=()

for run_id in "$@"; do
    # Resolve "latest" alias
    if [[ "$run_id" == "latest" ]]; then
        if [[ -L "$ARCHIVE_DIR/latest" ]]; then
            run_id="$(basename "$(readlink "$ARCHIVE_DIR/latest")")"
        else
            echo "Error: no 'latest' symlink in $ARCHIVE_DIR" >&2
            exit 1
        fi
    fi

    RUN_DIR="$ARCHIVE_DIR/runs/$run_id"
    RESULTS="$RUN_DIR/results.json"
    METADATA="$RUN_DIR/metadata.json"

    if [[ ! -f "$RESULTS" ]]; then
        echo "Error: results not found for run $run_id ($RESULTS)" >&2
        exit 1
    fi

    # Generate label from metadata
    if [[ -f "$METADATA" ]]; then
        LABEL=$(python3 -c "
import json
m = json.load(open('$METADATA'))
version = m.get('wheel', {}).get('version', '') if m.get('wheel') else ''
commit = m.get('wheel', {}).get('vllm_commit', '')[:9] if m.get('wheel') else ''
ts = m.get('timestamp', '')[:10]
# Format: dev<N> g<commit> (Mon DD)
parts = []
import re
dev_match = re.search(r'dev(\d+)', version)
if dev_match:
    parts.append(f'dev{dev_match.group(1)}')
if commit:
    parts.append(f'g{commit}')
if ts:
    from datetime import datetime
    try:
        dt = datetime.fromisoformat(ts)
        parts.append(f'({dt.strftime(\"%b %d\")})')
    except:
        parts.append(f'({ts})')
print(' '.join(parts) if parts else '$run_id')
")
    else
        LABEL="$run_id"
    fi

    LABELS+=("$LABEL")
    FILES+=("$RESULTS")
done

# Build compare.py command
# Use -- to separate --labels values from positional file args
CMD=(python3 "$COMPARE_SCRIPT")
if [[ ${#LABELS[@]} -gt 0 ]]; then
    CMD+=(--labels)
    for label in "${LABELS[@]}"; do
        CMD+=("$label")
    done
fi
CMD+=(--)
for f in "${FILES[@]}"; do
    CMD+=("$f")
done

echo "Running: ${CMD[*]}"
echo ""
exec "${CMD[@]}"
