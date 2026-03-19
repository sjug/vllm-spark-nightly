#!/bin/bash
# list-benchmarks.sh — List archived benchmark runs from index.json.
set -euo pipefail

ARCHIVE_DIR="${1:-$HOME/benchmarks}"
INDEX_FILE="$ARCHIVE_DIR/index.json"

if [[ ! -f "$INDEX_FILE" ]]; then
    echo "No archive found at $INDEX_FILE"
    echo "Run archive-benchmark.sh first."
    exit 1
fi

python3 -c "
import json, sys

with open('$INDEX_FILE') as f:
    index = json.load(f)

if not index:
    print('No archived runs.')
    sys.exit(0)

# Column widths
id_w = max(len('RUN_ID'), max(len(e['run_id']) for e in index))
ver_w = max(len('VLLM_VERSION'), max(len(e.get('vllm_version', '')) for e in index))
rec_w = max(len('RECIPE'), max(len(e.get('recipe', '')) for e in index))
host_w = max(len('HOST'), max(len(e.get('host', '')) for e in index))

header = f\"{'RUN_ID':<{id_w}}  {'VLLM_VERSION':<{ver_w}}  {'RECIPE':<{rec_w}}  {'HOST':<{host_w}}\"
print(header)
print('-' * len(header))

for entry in index:
    run_id = entry['run_id']
    version = entry.get('vllm_version', '')
    recipe = entry.get('recipe', '')
    host = entry.get('host', '')
    notes = entry.get('notes', '')
    line = f'{run_id:<{id_w}}  {version:<{ver_w}}  {recipe:<{rec_w}}  {host:<{host_w}}'
    if notes:
        line += f'  # {notes}'
    print(line)
"
