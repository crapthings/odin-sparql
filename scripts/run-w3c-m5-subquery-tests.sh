#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M5_SUBQUERY_SUITE:-}" ]; then
  suite=$W3C_M5_SUBQUERY_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/subquery"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_case() {
	total=$((total + 1))
	if ! "$runner" "$1" "$2" "$3"; then
		failed=$((failed + 1))
	fi
}

for name in sq08 sq09 sq10
do
  run_case "$suite/$name.rq" "$suite/$name.rdf" "$suite/$name.srx"
done
run_case "$suite/sq11.rq" "$suite/sq11.ttl" "$suite/sq11.srx"
run_case "$suite/sq12.rq" "$suite/sq12.ttl" "$suite/sq12_out.ttl"
run_case "$suite/sq13.rq" "$suite/sq13.ttl" "$suite/sq13.srx"
run_case "$suite/sq14.rq" "$suite/sq14.ttl" "$suite/sq14-out.ttl"

printf '%s\n' "W3C SPARQL M5 subquery subset: total=$total failed=$failed"
[ "$total" -eq 7 ]
[ "$failed" -eq 0 ]
