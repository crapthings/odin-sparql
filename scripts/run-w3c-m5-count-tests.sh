#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M5_AGGREGATES_SUITE:-}" ]; then
  suite=$W3C_M5_AGGREGATES_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/aggregates"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in agg01 agg02 agg03 agg04 agg05 agg06 agg07
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/agg01.ttl" "$suite/$name.srx"; then
    failed=$((failed + 1))
  fi
done
total=$((total + 1))
if ! "$runner" "$suite/agg-count-distinct.rq" "$suite/agg-numeric-duplicates.ttl" "$suite/agg-count-distinct.srx"; then
  failed=$((failed + 1))
fi
total=$((total + 1))
if ! "$runner" "$suite/agg-count-rows-distinct.rq" "$suite/agg-numeric-duplicates.ttl" "$suite/agg-count-rows-distinct.srx"; then
  failed=$((failed + 1))
fi
printf '%s\n' "W3C SPARQL M5 COUNT subset: total=$total failed=$failed"
[ "$total" -eq 9 ]
[ "$failed" -eq 0 ]
