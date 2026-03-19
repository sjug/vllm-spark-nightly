#!/bin/bash
# replay-wheel.sh — Restore an archived wheel for re-testing.
set -euo pipefail

ARCHIVE_DIR="$HOME/benchmarks"
DEST_DIR="$HOME/git/spark-vllm-docker/wheels"

usage() {
    cat <<'EOF'
Usage: replay-wheel.sh <run_id>

Copy the archived wheel from a benchmark run back to spark-vllm-docker/wheels/
and print the recipe launch command.

  "latest" is an alias for the most recent run.
EOF
    exit 0
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

RUN_ID="$1"

# Resolve "latest"
if [[ "$RUN_ID" == "latest" ]]; then
    if [[ -L "$ARCHIVE_DIR/latest" ]]; then
        RUN_ID="$(basename "$(readlink "$ARCHIVE_DIR/latest")")"
    else
        echo "Error: no 'latest' symlink in $ARCHIVE_DIR" >&2
        exit 1
    fi
fi

RUN_DIR="$ARCHIVE_DIR/runs/$RUN_ID"
METADATA="$RUN_DIR/metadata.json"

if [[ ! -f "$METADATA" ]]; then
    echo "Error: metadata not found for run $RUN_ID ($METADATA)" >&2
    exit 1
fi

# Read wheel info and recipe from metadata
WHEEL_FILENAME=$(python3 -c "
import json
m = json.load(open('$METADATA'))
wheel = m.get('wheel') or {}
print(wheel.get('filename', ''))
")
RECIPE_NAME=$(python3 -c "
import json
m = json.load(open('$METADATA'))
recipe = m.get('recipe') or {}
print(recipe.get('name', ''))
")

if [[ -z "$WHEEL_FILENAME" ]]; then
    echo "Error: no wheel recorded for run $RUN_ID" >&2
    exit 1
fi

# Find the wheel — check run dir first, then dedup store
WHEEL_SRC=""
if [[ -f "$RUN_DIR/$WHEEL_FILENAME" ]]; then
    WHEEL_SRC="$RUN_DIR/$WHEEL_FILENAME"
elif [[ -f "$ARCHIVE_DIR/wheels/$WHEEL_FILENAME" ]]; then
    WHEEL_SRC="$ARCHIVE_DIR/wheels/$WHEEL_FILENAME"
else
    echo "Error: wheel file not found: $WHEEL_FILENAME" >&2
    echo "Checked: $RUN_DIR/ and $ARCHIVE_DIR/wheels/" >&2
    exit 1
fi

# Copy to destination
mkdir -p "$DEST_DIR"
cp "$WHEEL_SRC" "$DEST_DIR/$WHEEL_FILENAME"
echo "Copied wheel to $DEST_DIR/$WHEEL_FILENAME"

# Print launch instructions
echo ""
if [[ -n "$RECIPE_NAME" ]]; then
    echo "Run:"
    echo "  cd ~/git/spark-vllm-docker && ./build-and-copy.sh && ./run-recipe.sh $RECIPE_NAME --solo -d"
else
    echo "Run:"
    echo "  cd ~/git/spark-vllm-docker && ./build-and-copy.sh && ./run-recipe.sh <recipe> --solo -d"
fi
