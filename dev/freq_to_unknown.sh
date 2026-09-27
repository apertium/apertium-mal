#!/usr/bin/env bash
#
# freq_to_unknown.sh — derive the unknown-word list from analysed output.
#
# Pure unix pipeline (grep/sed/awk/sort/uniq). No python, no extra deps.
# Sorting-based counting streams in constant memory, unlike hash counting.
#
# Two locale rules matter here (macOS BSD tools):
#   * sort/uniq MUST run under LC_ALL=C. Under a UTF-8 locale, collation
#     considers distinct Malayalam strings equal, so uniq -c merges them
#     and sort -u drops them. Byte order == codepoint order for UTF-8,
#     so C-locale sorting stays deterministic and meaningful.
#   * Character counting (single-char skip) needs a UTF-8 locale, where
#     grep is multibyte-aware (macOS awk is byte-oriented regardless).
#     $UTF8LOC auto-detects one; every other step is byte-safe by design
#     (ASCII delimiters, explicit U+0D00-U+0D7F ranges, byte-contiguous
#     in UTF-8).
#
# Two operations, run in order:
#   1. freq:    analysed.txt (lt-proc -w stream) -> allwords_freq.tsv
#              every surface form with total count, known/unknown status
#              and sample analyses, sorted by count desc.
#   2. unknown: allwords_freq.tsv -> unknown_freq.tsv + stats.txt
#              keeps only unrecognised Malayalam-script words of 2+ chars
#              (count<TAB>word, sorted by count desc).
#
# Usage:
#   ./dev/freq_to_unknown.sh ANALYSED_FILE OUT_DIR [freq|unknown|both]
#   MINLEN=2 ./dev/freq_to_unknown.sh ...   # min word length in chars
#
set -euo pipefail
export LC_ALL=C
# First UTF-8 locale for character counting (grep is multibyte-aware).
# NOTE: no `grep -m1|head` shortcut here: under `set -o pipefail` the
# producer gets SIGPIPE and the fallback would append a stray "C".
UTF8LOC=C
while IFS= read -r loc; do
    case "$loc" in *[Uu][Tt][Ff]*8*) UTF8LOC="$loc"; break ;; esac
done < <(locale -a 2>/dev/null)
MINLEN="${MINLEN:-2}"

[[ $# -ge 2 ]] || { echo "usage: $0 ANALYSED_FILE OUT_DIR [freq|unknown|both]" >&2; exit 1; }
ANALYSED="$1"
OUTDIR="$2"
STAGE="${3:-both}"
[[ -f "$ANALYSED" ]] || { echo "error: not found: $ANALYSED" >&2; exit 1; }
mkdir -p "$OUTDIR"

FREQ="$OUTDIR/allwords_freq.tsv"
UNKFREQ="$OUTDIR/unknown_freq.tsv"
STATS="$OUTDIR/stats.txt"
TAB="$(printf '\t')"

# ------------------------------------------------------- 1. frequency -------
# One token per line -> "status<TAB>surface<TAB>sample" -> sort|uniq -c.
# A token is unknown iff its whole analysis is "*surface" (no real reading).
if [[ "$STAGE" == freq || "$STAGE" == both ]]; then
    echo "== building full frequency list -> $FREQ ..."
    grep -o '\^[^^$]*\$' "$ANALYSED" \
    | awk -v TAB="$TAB" '{ i = index($0, "/"); surf = substr($0, 2, i - 2); ana = substr($0, i + 1);
             sub(/\$$/, "", ana);
             if (length(surf) == 0) next;
             n = split(ana, a, "/");
             sample = a[1]; if (n > 1) sample = sample "/" a[2];
             print ((ana == ("*" surf)) ? "unknown" : "known") TAB surf TAB sample }' \
    | sort \
    | uniq -c \
    | awk -v TAB="$TAB" '{ c = $1; sub(/^ *[0-9]+ /, ""); n = split($0, f, "\t");
             print c TAB f[1] TAB f[2] TAB f[3] }' \
    | sort -t"$TAB" -k1,1nr -k2,2 \
    > "$FREQ"
    echo "  surfaces: $(wc -l < "$FREQ"), tokens: $(awk -F"$TAB" '{t += $1} END {print t}' "$FREQ")"
fi

# -------------------------------------------------------- 2. unknowns -------
# Unknown Malayalam words of MINLEN+ chars, punctuation stripped, counts
# re-aggregated (stripping can merge surfaces), sorted by count desc.
if [[ "$STAGE" == unknown || "$STAGE" == both ]]; then
    [[ -f "$FREQ" ]] || { echo "error: run the freq stage first: $FREQ missing" >&2; exit 1; }
    echo "== deriving unknown-word list (minlen=$MINLEN) -> $UNKFREQ ..."
    awk -F"$TAB" '$2 == "unknown" { print $3 "\t" $1 }' "$FREQ" \
    | sed -E 's/^[^A-Za-z0-9_ഀ-ൿ]+//; s/[^A-Za-z0-9_ഀ-ൿ]+$//' \
    | grep '[ഀ-ൿ]' \
    | LC_ALL="$UTF8LOC" grep "^.\{$MINLEN,\}.*\t" \
    | sort -t"$TAB" -k1,1 \
    | awk -F"$TAB" '{ if ($1 == prev) s += $2;
                     else { if (NR > 1) print s "\t" prev; prev = $1; s = $2 } }
                   END { if (NR > 0) print s "\t" prev }' \
    | sort -t"$TAB" -k1,1nr -k2,2 \
    > "$UNKFREQ"
    # stats: totals from freq list, malayalam-unknown totals from unknown list
    total=$(awk -F"$TAB" '{t += $1} END {print t}' "$FREQ")
    utotal=$(awk -F"$TAB" '$2 == "unknown" {u += $1} END {print u+0}' "$FREQ")
    mtotal=$(awk -F"$TAB" '{m += $1} END {print m+0}' "$UNKFREQ")
    distinct=$(wc -l < "$UNKFREQ")
    known=$((total - utotal))
    cov=$(awk -v k="$known" -v t="$total" 'BEGIN {printf "%.2f", (t ? 100*k/t : 0)}')
    printf 'total_tokens: %s\nunknown_tokens: %s\nunknown_malayalam_tokens: %s\ndistinct_unknown_malayalam: %s\ncoverage_pct: %s\n' \
        "$total" "$utotal" "$mtotal" "$distinct" "$cov" > "$STATS"
    cat "$STATS"
    echo "== top 20 missing words =="
    head -n 20 "$UNKFREQ"
fi
echo "== done."
