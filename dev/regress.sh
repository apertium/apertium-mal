#!/usr/bin/env bash
#
# regress.sh — old-vs-new analyser binary comparison.
#
# Runs OLD and NEW mal.automorf.bin over the same sanitised input and
# compares knowship (known vs ^surf/*surf$ unknown), NOT exact analysis
# strings: lemmas legitimately change form (non-atomic -> atomic).
#
# Usage: ./dev/regress.sh OLD_BIN NEW_BIN SENTENCES [N]
#   N = head limit, 0 = all (default 50000 for a quick check)
#
set -euo pipefail
OLD="$1"; NEW="$2"; SENTS="$3"; N="${4:-50000}"
[[ -f "$OLD" && -f "$NEW" && -f "$SENTS" ]] || { echo "usage: $0 OLD_BIN NEW_BIN SENTENCES [N]" >&2; exit 1; }
command -v lt-proc >/dev/null || { echo "error: lt-proc not found" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if (( N > 0 )); then head -n "$N" "$SENTS" > "$WORK/in.txt"; else cp "$SENTS" "$WORK/in.txt"; fi

# same sanitise as wiki_unknown_freq.sh (keep in sync on purpose: duplication
# beats sourcing, which would execute that script's main body)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed -f "$REPO_ROOT/dev/chillu_nonatomic_to_atomic.sed" "$WORK/in.txt" \
| sed -E -e 's|https?://[^[:space:]]*||g' -e 's|www\.[^[:space:]]*||g' \
| tr '/^$@[]{}<>' '          ' > "$WORK/clean.txt"

export LC_ALL=C
for v in OLD NEW; do
  bin="${!v}"
  lt-proc -w "$bin" < "$WORK/clean.txt" 2>/dev/null > "$WORK/$v.out"
  grep -o '\^[^^$]*\$' "$WORK/$v.out" \
  | awk '{ i = index($0, "/"); surf = substr($0, 2, i - 2); ana = substr($0, i + 1);
           sub(/\$$/, "", ana); if (length(surf)) print surf "\t" ((ana == ("*" surf)) ? "U" : "K") }' \
  | sort -u > "$WORK/$v.surf"
done

echo "== knowship (distinct surfaces) =="
join -t'	' -j1 -o 0,1.2,2.2 "$WORK/OLD.surf" "$WORK/NEW.surf" > "$WORK/both.tsv" || true
awk -F'	' '$2=="K" && $3=="K" {kk++} $2=="K" && $3=="U" {reg++} $2=="U" && $3=="K" {pick++} $2=="U" && $3=="U" {uu++}
             END {printf "still-known: %d\nREGRESSIONS (old-K,new-U): %d\npickups (old-U,new-K): %d\nstill-unknown: %d\n", kk, reg, pick, uu}' "$WORK/both.tsv"
echo "== sample regressions (old knew, new doesn't) =="
awk -F'	' '$2=="K" && $3=="U" {print $1}' "$WORK/both.tsv" | head -n 20
