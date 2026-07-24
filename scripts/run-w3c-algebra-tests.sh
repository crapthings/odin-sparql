#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_ALGEBRA_SUITE:-}" ]; then
  suite=$W3C_ALGEBRA_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/algebra"
fi
runner="$root/.cache/odin-sparql-basic-runner"
base="http://example/"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" --base "$base" "$suite/$1.rq" "$suite/$2" "$suite/$1.srx"; then
    failed=$((failed + 1))
  fi
}

run_case join-combo-1 join-combo-graph-2.ttl
run_case two-nested-opt two-nested-opt.ttl
run_case two-nested-opt-alt two-nested-opt.ttl
run_case opt-filter-1 opt-filter-1.ttl
run_case opt-filter-2 opt-filter-2.ttl
run_case opt-filter-3 opt-filter-3.ttl
run_case filter-placement-1 data-2.ttl
run_case filter-placement-2 data-2.ttl
run_case filter-placement-3 data-2.ttl
run_case filter-nested-1 data-1.ttl
run_case filter-nested-2 data-1.ttl
run_case filter-scope-1 data-2.ttl
run_case var-scope-join-1 var-scope-join-1.ttl

# This entry has one default graph and one qt:graphData named graph. Its
# relative data IRIs are resolved using the official http://example/ base.
total=$((total + 1))
if ! "$runner" --mixed "$suite/join-combo-2.rq" "$suite/join-combo-2.srx" '' "$base" "$suite/join-combo-graph-2.ttl" "${base}graph" "$suite/join-combo-graph-1.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL algebra: total=$total failed=$failed"
[ "$total" -eq 14 ]
[ "$failed" -eq 0 ]
