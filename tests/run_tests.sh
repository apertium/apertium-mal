#!/usr/bin/env bash
#
# run_tests.sh — run the tests/*.yaml testvoc suites.
#
# For each `analysis : surface` pair, checks both directions with lt-proc:
#   generation:  ^analysis$ | lt-proc -g mal.autogen.bin  == surface
#   morphology:  surface | lt-proc -w mal.automorf.bin  contains /analysis/
#
# Uses lt-proc + .bin, NOT hfst-lookup + .hfst: hfst-invert drops the
# epsilon-heavy clitic paths, so mal.automorf.hfst cannot analyse forms
# that lt-proc -w mal.automorf.bin handles (verified empirically).
#
# Usage: ./tests/run_tests.sh [repo-root]   (default: parent of tests/)
# Exit 0 iff every pair passes in both directions.
#
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MORF="$ROOT/mal.automorf.bin"
GEN="$ROOT/mal.autogen.bin"

command -v lt-proc >/dev/null 2>&1 || { echo "error: lt-proc not found" >&2; exit 2; }
[[ -f "$MORF" ]] || { echo "error: not found: $MORF (run make first)" >&2; exit 2; }
[[ -f "$GEN" ]] || { echo "error: not found: $GEN (run make first)" >&2; exit 2; }

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

pass=0
fail=0
npair=0
for yaml in "$ROOT"/tests/*.yaml; do
  [[ -f "$yaml" ]] || { echo "error: no yaml tests in $ROOT/tests" >&2; exit 2; }
  echo "== $yaml"
  while IFS= read -r line || [[ -n "$line" ]]; do
    t="$(printf '%s' "$line" | trim)"
    case "$t" in
      ''|'Config:'*|'hfst:'*|'App:'*|'Gen:'*|'Morph:'*|'Tests:'*|'"'*) continue ;;
    esac
    case "$t" in
      *' : '*) ;;
      *) continue ;;
    esac
    ana="$(printf '%s' "${t%% : *}" | trim)"
    surf="$(printf '%s' "${t#* : }" | trim)"
    [[ -n "$ana" && -n "$surf" ]] || continue
    npair=$((npair + 1))

    g="$(printf '^%s$' "$ana" | lt-proc -g "$GEN" 2>/dev/null)"
    m="$(printf '%s' "$surf" | lt-proc -w "$MORF" 2>/dev/null)"

    ok=1
    [[ "$g" == "$surf" ]] || ok=0
    case "$m" in
      *"/$ana/"*|*"/$ana\$"*) ;;
      *) ok=0 ;;
    esac
    if (( ok )); then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL: $ana : $surf"
      [[ "$g" == "$surf" ]] || echo "  gen gave: $g"
      case "$m" in
        *"/$ana/"*|*"/$ana\$"*) ;;
        *) echo "  mor gave: $m" ;;
      esac
    fi
  done < "$yaml"
done

echo "--"
echo "pairs: $npair  pass: $pass  fail: $fail"
(( fail == 0 ))
