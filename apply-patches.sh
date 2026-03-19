#!/bin/bash
# apply-patches.sh — Reads patches.json and applies/reverts PR diffs to vLLM source.
# Non-fatal on failure: logs which patches succeeded/failed.
# Outputs a summary file (patches-applied.txt) for use in release notes.
set -uo pipefail

PATCHES_FILE="${1:-patches.json}"
SUMMARY_FILE="/tmp/patches-applied.txt"

if [ ! -f "$PATCHES_FILE" ]; then
    echo "No patches.json found — skipping patch step."
    exit 0
fi

> "$SUMMARY_FILE"

# Process reverts
REVERTS=$(python3 -c "
import json, sys
data = json.load(open('$PATCHES_FILE'))
for r in data.get('reverts', []):
    print(f\"{r['pr']} {r.get('reason', 'no reason given')}\")
" 2>/dev/null)

if [ -n "$REVERTS" ]; then
    echo "=== Reverting PRs ==="
    while IFS=' ' read -r PR REASON; do
        echo "Reverting PR #${PR} (${REASON})..."
        if curl -fL "https://github.com/vllm-project/vllm/pull/${PR}.diff" | patch -p1 -R; then
            echo "REVERTED #${PR}: ${REASON}" >> "$SUMMARY_FILE"
            echo "  -> Reverted successfully."
        else
            echo "FAILED_REVERT #${PR}: ${REASON}" >> "$SUMMARY_FILE"
            echo "  -> Cannot revert PR #${PR}, skipping."
        fi
    done <<< "$REVERTS"
fi

# Process applies
APPLIES=$(python3 -c "
import json, sys
data = json.load(open('$PATCHES_FILE'))
for a in data.get('applies', []):
    print(f\"{a['pr']} {a.get('reason', 'no reason given')}\")
" 2>/dev/null)

if [ -n "$APPLIES" ]; then
    echo "=== Applying PRs ==="
    while IFS=' ' read -r PR REASON; do
        [ -z "$PR" ] && continue
        echo "Applying PR #${PR} (${REASON})..."
        if curl -fL "https://github.com/vllm-project/vllm/pull/${PR}.diff" | git apply -v; then
            echo "APPLIED #${PR}: ${REASON}" >> "$SUMMARY_FILE"
            echo "  -> Applied successfully."
        else
            echo "FAILED_APPLY #${PR}: ${REASON}" >> "$SUMMARY_FILE"
            echo "  -> Cannot apply PR #${PR}, skipping."
        fi
    done <<< "$APPLIES"
fi

echo ""
echo "=== Patch Summary ==="
if [ -s "$SUMMARY_FILE" ]; then
    cat "$SUMMARY_FILE"
else
    echo "No patches configured."
fi
