#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_SOLUTION_SEQ_SUITE:-}" ]; then
  suite=$W3C_SOLUTION_SEQ_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/solution-seq"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for suffix in 01 02 03 04 10 11 12 13 20 21 22 23 24
do
  total=$((total + 1))
  if ! "$runner" "$suite/slice-$suffix.rq" "$suite/data.ttl" "$suite/slice-results-$suffix.ttl"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL solution sequence: total=$total failed=$failed"
[ "$total" -eq 13 ]
[ "$failed" -eq 0 ]
