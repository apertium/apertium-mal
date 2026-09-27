#!/usr/bin/env bash
#
# wiki_unknown_freq.sh — find Malayalam words missing from the analyser.
#
# Pulls the smcproject/ml-wiki-sentences dataset from Hugging Face
# (single resumable parquet download — no thousands of API requests),
# streams every sentence through the apertium-mal morphological analyser
# (lt-proc -w mal.automorf.bin), collects the surface forms the analyser
# does NOT recognise (the ^word/*word$ outputs) and writes them out
# sorted by descending frequency, so the most important gaps can be
# worked on first.
#
# Before analysis, non-atomic chillu sequences (consonant + virama + ZWJ)
# are normalised to atomic chillu codepoints (U+0D7A..U+0D7F).
#
# Usage:
#   ./dev/wiki_unknown_freq.sh [options]
#
# Options (or same-name env vars):
#   -d DIR    working/data directory            (DATA_DIR, default: dev/wiki_data)
#   -l N      max sentences to process, 0 = all (LIMIT, default: 0 = all 2250217)
#   -o N      start offset into the split       (OFFSET, default: 0)
#   -b N      sentences per analyse chunk       (BATCH, default: 5000)
#   -a FILE   analyser binary                   (ANALYSER, default: mal.automorf.bin
#                                                next to repo root)
#   -p FILE   local parquet file                (PARQUET, default: DATA_DIR/ml-wiki-sentences.parquet;
#                                                downloaded if missing)
#   -f        force re-download even if sentences.txt exists
#   -h        this help
#
# Outputs (in DATA_DIR, all git-ignored):
#   ml-wiki-sentences.parquet  raw dataset, one resumable download (~240M)
#   sentences.txt      one raw sentence per line (downloaded corpus)
#   analysed.txt       raw lt-proc -w output stream
#   allwords_freq.tsv  "count<TAB>surface<TAB>known|unknown<TAB>samples"
#   unknown_freq.tsv   "count<TAB>word" sorted by count desc  <-- main result
#   stats.txt          total/known/unknown token counts + coverage %
#
# Sanitising (sanitise() below, pure unix tools) before analysis:
#   non-atomic chillu -> atomic (dev/chillu_nonatomic_to_atomic.sed,
#   generated — do not hand-edit), stray ZWJ/ZWNJ/BOM deleted, URLs
#   stripped, lt-proc-fatal chars ([/^$@[]{}<>]) blanked.
#
# Requirements: bash, curl, python3, lt-proc. Parquet extraction needs
# the `pyarrow` pip package (pip install pyarrow). Without it, the script
# falls back to the datasets-server HTTP rows API (stdlib only, slow).
#
set -euo pipefail

DATASET="smcproject/ml-wiki-sentences"
CONFIG="default"
SPLIT="train"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/dev/wiki_data}"
LIMIT="${LIMIT:-0}"
OFFSET="${OFFSET:-0}"
BATCH="${BATCH:-5000}"
ANALYSER="${ANALYSER:-$REPO_ROOT/mal.automorf.bin}"
REFETCH=0

usage() { sed -n '2,/^#$/p' "$0" | sed 's/^# \?//'; }

while getopts "d:l:o:b:a:p:fh" opt; do
    case "$opt" in
        d) DATA_DIR="$OPTARG" ;;
        l) LIMIT="$OPTARG" ;;
        o) OFFSET="$OPTARG" ;;
        b) BATCH="$OPTARG" ;;
        a) ANALYSER="$OPTARG" ;;
        p) PARQUET="$OPTARG" ;;
        f) REFETCH=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
command -v lt-proc >/dev/null || { echo "error: lt-proc not found" >&2; exit 1; }
[[ -f "$ANALYSER" ]] || { echo "error: analyser not found: $ANALYSER" >&2; exit 1; }

mkdir -p "$DATA_DIR"
SENTENCES="$DATA_DIR/sentences.txt"
ANALYSED="$DATA_DIR/analysed.txt"
# (freq_to_unknown.sh derives allwords_freq.tsv/unknown_freq.tsv/stats.txt
# inside DATA_DIR from ANALYSED; see final stage.)
PARQUET="${PARQUET:-$DATA_DIR/ml-wiki-sentences.parquet}"
PARQUET_URL="https://huggingface.co/api/datasets/smcproject/ml-wiki-sentences/parquet/default/train/0.parquet"

export DATASET CONFIG SPLIT DATA_DIR SENTENCES LIMIT OFFSET BATCH PARQUET

# ---------------------------------------------------------------- fetch ---
# Preferred: single resumable parquet download (one HTTP request), then
# extract the `sentence` column locally. Falls back to the datasets-server
# rows API (stdlib only, ~100 rows/request) when pyarrow is unavailable.
# Skipped when sentences.txt already exists, unless -f is given.
if [[ "$REFETCH" -eq 1 || ! -s "$SENTENCES" ]]; then
    if python3 -c "import pyarrow" 2>/dev/null; then
        if [[ ! -s "$PARQUET" ]]; then
            echo "== downloading parquet (one request, resumable) ..."
            curl -L -C - -o "$PARQUET" "$PARQUET_URL"
        else
            echo "== reusing existing $PARQUET"
        fi
        echo "== extracting sentences (limit=$LIMIT offset=$OFFSET) ..."
        python3 - "$PARQUET" "$SENTENCES" <<'EOF'
import os, sys
import pyarrow.parquet as pq
parquet_path, out_path = sys.argv[1], sys.argv[2]
limit, offset = int(os.environ["LIMIT"]), int(os.environ["OFFSET"])
t = pq.read_table(parquet_path, columns=["sentence"])
total = t.num_rows
end = total if not limit else min(total, offset + limit)
sents = t.column("sentence").to_pylist()[offset:end]
with open(out_path, "w", encoding="utf-8") as out:
    for s in sents:
        out.write((s or "").replace("\n", " ").strip() + "\n")
print(f"wrote {len(sents)} sentences (rows {offset}..{end} of {total}) -> {out_path}")
EOF
    else
        echo "== pyarrow not found; falling back to rows API (slow). pip install pyarrow for the fast path."
        python3 - "$SENTENCES" <<'EOF'
import json, os, sys, urllib.request

dataset, config, split = os.environ["DATASET"], os.environ["CONFIG"], os.environ["SPLIT"]
out_path = sys.argv[1]
limit, offset = int(os.environ["LIMIT"]), int(os.environ["OFFSET"])
page = min(int(os.environ["BATCH"]), 100)  # /rows API allows length<=100

# Ask the server how many rows exist (first call returns no rows if length=0,
# so fetch one row and read num_rows_total).
def get_rows(off, length):
    url = (f"https://datasets-server.huggingface.co/rows?dataset={dataset}"
           f"&config={config}&split={split}&offset={off}&length={length}")
    with urllib.request.urlopen(url) as r:
        return json.load(r)

probe = get_rows(offset, 1)
total = probe.get("num_rows_total") or 0
if total and limit:
    total = min(total, offset + limit) - offset
elif limit:
    total = limit
elif total:
    total = total - offset
else:
    raise SystemExit("error: could not determine row count; is the dataset visible? "
                     "https://huggingface.co/datasets/" + dataset)
print(f"server reports rows; fetching {total} sentences ({page}/request)...")

fetched = 0
with open(out_path, "w", encoding="utf-8") as out:
    while fetched < total:
        n = min(page, total - fetched)
        d = get_rows(offset + fetched, n)
        rows = d.get("rows", [])
        if not rows:
            break
        for r in rows:
            s = (r["row"].get("sentence") or "").replace("\n", " ").strip()
            out.write(s + "\n")
        fetched += len(rows)
        print(f"  {fetched}/{total}", flush=True)
print(f"wrote {fetched} sentences -> {out_path}")
EOF
    fi
else
    echo "== reusing existing $SENTENCES ($(wc -l < "$SENTENCES") lines; use -f to re-download)"
fi

# ------------------------------------------------------------- sanitise ---
# lt-proc -w aborts the whole stream on a malformed token. These inputs are
# known to break it: bare '/' (URLs), ^ $ ] { } @ < > (stream/tag syntax).
# Strip URLs and replace the offenders with blanks before analysing.
echo "== sanitising + analysing with lt-proc -w $ANALYSER ..."
echo "  ($(wc -l < "$SENTENCES") sentences)"

# Stream in chunks so one bad line can never silently kill the whole run:
# a failed chunk is retried line-by-line, dropping only the offending lines.
: > "$ANALYSED"
CHUNKDIR="$(mktemp -d)"
trap 'rm -rf "$CHUNKDIR"' EXIT
trap 'echo; echo "interrupted at chunk $chunk_i; partial outputs kept in $DATA_DIR"; rm -rf "$CHUNKDIR"; exit 130' INT TERM
split -l "$BATCH" "$SENTENCES" "$CHUNKDIR/sent."
NCHUNKS="$(ls "$CHUNKDIR"/sent.* | wc -l)"

sanitise() {
    # stdin -> stdout, pure unix tools:
    #   1. non-atomic chillu -> atomic + delete stray ZWJ/ZWNJ/BOM
    #      (dev/chillu_nonatomic_to_atomic.sed, generated — do not hand-edit)
    #   2. strip URLs, blank chars fatal to lt-proc (tr: byte-safe ASCII)
    sed -f "$REPO_ROOT/dev/chillu_nonatomic_to_atomic.sed" \
    | sed -E -e 's|https?://[^[:space:]]*||g' -e 's|www\.[^[:space:]]*||g' \
    | tr '/^$@[]{}<>' '          '
}

chunk_i=0
for chunk in "$CHUNKDIR"/sent.*; do
    chunk_i=$((chunk_i + 1))
    if sanitise < "$chunk" | lt-proc -w "$ANALYSER" >> "$ANALYSED" 2>"$CHUNKDIR/err.$chunk_i"; then
        if (( chunk_i % 25 == 0 )) || (( chunk_i == NCHUNKS )); then echo "  chunk $chunk_i/$NCHUNKS"; fi
    else
        echo "  chunk $chunk_i hit malformed input; retrying line-by-line ..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" | sanitise | lt-proc -w "$ANALYSER" >> "$ANALYSED" 2>/dev/null || true
        done < "$chunk"
    fi
done
echo "== analysed stream -> $ANALYSED ($(wc -c < "$ANALYSED") bytes)"

# --------------------------------------- frequency + unknown lists ----
# Two-stage derivation via dev/freq_to_unknown.sh (pure unix pipeline):
#   1. allwords_freq.tsv (every surface + known/unknown status),
#   2. unknown_freq.tsv + stats.txt (Malayalam, MINLEN+ chars).
# Re-runnable on demand without re-analysing:
#   ./dev/freq_to_unknown.sh dev/wiki_data/analysed.txt dev/wiki_data both
MINLEN="${MINLEN:-2}"
export MINLEN
"$REPO_ROOT/dev/freq_to_unknown.sh" "$ANALYSED" "$DATA_DIR" both
