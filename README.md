# apertium-mal: coverage-driven work notes

apertium-mal is the Apertium morphological analyser for Malayalam:
a lexc lexicon plus a twol rule file, compiled to `mal.automorf.bin`
(analysis) and `mal.autogen.bin` (generation) with the HFST toolchain.
This file documents the practical side — building it, measuring what it
doesn't know yet, and the Unicode pitfalls that ate most of the debugging
time. For agent-oriented notes see AGENTS.md.

## Building

The checked-in `Makefile` was generated on another machine and references
a stale absolute path, so `make` fails here. The reliable way is to run
the same steps by hand (needs `hfst-twolc hfst-lexc hfst-compose-intersect
hfst-invert hfst-fst2fst hfst-fst2txt lt-comp`; `lt-proc` to test):

```
hfst-twolc apertium-mal.mal.twol -o .deps/mal.twol.hfst
grep -v 'Dir/LR' apertium-mal.mal.lexc > .deps/mal.LR.lexc
hfst-lexc --format foma .deps/mal.LR.lexc -o .deps/mal.LR.lexc.hfst
hfst-compose-intersect -1 .deps/mal.LR.lexc.hfst -2 .deps/mal.twol.hfst \
    -o .deps/mal.LR.hfst
hfst-invert .deps/mal.LR.hfst | hfst-fst2fst -O -o mal.automorf.hfst
hfst-fst2txt mal.automorf.hfst | gzip -9 -c -n > mal.automorf.att.gz
zcat < mal.automorf.att.gz > .deps/mal.automorf.att
lt-comp lr .deps/mal.automorf.att mal.automorf.bin
```

Same with `Dir/RL` filtered and no invert for `mal.autogen.*`.
Smoke test: `echo 'മലയാളം' | lt-proc -w mal.automorf.bin`
should print `^മലയാളം/മലയാളം<n><sg><nom>$`.
Known analyser output is `^surface/analysis$`; unknown words come back as
`^surface/*surface$` — that marker is what the coverage scripts key on.

One warning from experience: always keep a copy of the last good `.bin`
before rebuilding (`cp mal.automorf.bin /tmp/...`), and diff old-vs-new
with `dev/regress.sh` (needs both binaries plus a sentence file).
A rebuild that "succeeds" can still silently drop words — see below.

## Measuring coverage

`dev/wiki_unknown_freq.sh` pulls the Malayalam Wikipedia sentence corpus
(`smcproject/ml-wiki-sentences`, 2.25M sentences) as one parquet download
(~240 MB, needs `pip install pyarrow`; without it the script falls back to
a much slower rows API), runs every sentence through the analyser, and
`dev/freq_to_unknown.sh` turns the output into two files: `allwords_freq.tsv`
(everything, with known/unknown flags) and `unknown_freq.tsv`
(`count<TAB>word`, most frequent first). That second file is the work list:
add the top entries to the lexicon first.

Current snapshot (full corpus, analyser as committed here):

- tokens: FIXME, coverage: FIXME%
- top missing (multi-char Malayalam, frequency order): FIXME

## The chillu situation

Malayalam chillu letters (ൻ ർ ൽ ൾ ൺ ൿ) exist in two Unicode spellings:
atomic single codepoints (`U+0D7A`–`U+0D7F`, what Wikipedia and phones
produce) and the legacy consonant+virama+ZWJ sequence. Unicode does not
treat them as equivalent and neither does this analyser out of the box —
the lexicon historically stored the legacy form, so atomic input failed.

What was done here: the lexc was converted entry-by-entry to atomic
*only where the surface side already carried chillu* (315 entries), mixed
entries like `രണ്ട്:രണ്ടു` deliberately left alone, and the input pipeline
normalises legacy sequences to atomic before analysis. The twol gained
atomic variants of the r→ṟ rules. Bare-virama spellings (`അവന്`) and
stray ZWJs are handled in sanitising, not in the transducer.

Two things to know before touching this area: nominative chillu is often
compositional (stem `അവന` + suffix piece `:്‍`), which no twol rule can
retarget at atomic input — that needs per-consonant suffix routing and is
still open. And the clitics tests in `tests/` were already failing before
any of this (`make test` prints TODO); treat them as intent, not green CI.

## Gotchas that actually bit

- `lt-proc -w` aborts the whole stream on `/ ^ $ ] { } @ < >` in the
  input. Sanitise URLs and those characters away, and analyse in chunks
  so one bad line can't kill a 2M-sentence run.
- macOS `sort`/`uniq` under a UTF-8 locale consider distinct Malayalam
  strings equal (collation) and silently merge them. All counting steps
  run under `LC_ALL=C`; only the character-length filter uses a UTF-8
  locale, auto-detected. Related: BSD `uniq -c` doesn't pad wide counts,
  so parse them with `sub(/^ *[0-9]+ /, "")`, and never combine
  `set -o pipefail` with `grep -m1|head` fallbacks (SIGPIPE appends junk).
- hfst-twolc rejects multiple rules sharing one `"name"` string with a
  parse error on the second rule. One name per rule.
- Never `source` the pipeline scripts to test a function (they execute
  the main body), and never edit them mid-run.
