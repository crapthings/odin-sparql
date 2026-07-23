#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M5_AGGREGATES_SUITE:-}" ]; then
  suite=$W3C_M5_AGGREGATES_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/aggregates"
fi
runner="$root/.cache/odin-sparql-syntax-runner"

odin build "$root/tests/w3c/syntax_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$1" "$suite/$2"; then
    failed=$((failed + 1))
  fi
}

run_case negative agg08.rq
run_case negative agg09.rq
run_case negative agg10.rq
run_case negative agg11.rq
run_case negative agg12.rq
run_case positive agg08b.rq

printf '%s\n' "W3C SPARQL M5 aggregate scope syntax: total=$total failed=$failed"
[ "$total" -eq 6 ]
[ "$failed" -eq 0 ]
