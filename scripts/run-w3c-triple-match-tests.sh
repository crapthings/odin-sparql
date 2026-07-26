#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_TRIPLE_MATCH_SUITE:-}" ]; then
  suite=$W3C_TRIPLE_MATCH_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/triple-match"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$suite/$1.rq" "$suite/$2" "$suite/$3"; then
    failed=$((failed + 1))
  fi
}

run_case dawg-tp-01 data-01.ttl result-tp-01.ttl
run_case dawg-tp-02 data-01.ttl result-tp-02.ttl
run_case dawg-tp-03 data-02.ttl result-tp-03.ttl

# dawg-data-01.ttl contains <fred@edu>, a relative IRI. The published test
# suite's document location is its required Turtle base rather than an engine
# query base, so load it explicitly through the runner's fixture-data option.
total=$((total + 1))
if ! "$runner" --base "http://www.w3.org/2001/sw/DataAccess/tests/data-r2/triple-match/" "$suite/dawg-tp-04.rq" "$suite/dawg-data-01.ttl" "$suite/result-tp-04.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL triple match: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
