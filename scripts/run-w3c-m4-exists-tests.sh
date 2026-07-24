#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_NEGATION_SUITE:-}" ]; then
  suite=$W3C_M4_NEGATION_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/negation"
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

for name in exists-01 exists-02 subsetByExcl01 subsetByExcl02 temporalProximity01 subset-01 subset-02 subset-03 set-equals-1
do
  data="$suite/set-data.ttl"
  case "$name" in
    subsetByExcl01|subsetByExcl02) data="$suite/subsetByExcl.ttl" ;;
    temporalProximity01) data="$suite/temporalProximity01.ttl" ;;
  esac
  run_case "$suite/$name.rq" "$data" "$suite/$name.srx"
done
total=$((total + 1))
graph_base="http://www.w3.org/2009/sparql/tests/data-sparql11/negation/"
if ! "$runner" --named "$suite/graph-minus.rq" "$suite/graph-minus.srx" "$graph_base" \
  "$graph_base"graph-minus.ttl "$suite/graph-minus.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL M4 negation subset: total=$total failed=$failed"
[ "$total" -eq 10 ]
[ "$failed" -eq 0 ]
