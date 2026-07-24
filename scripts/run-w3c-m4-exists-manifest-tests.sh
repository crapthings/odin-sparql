#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_EXISTS_SUITE:-}" ]; then
  suite=$W3C_M4_EXISTS_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/exists"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_default() {
  total=$((total + 1))
  if ! "$runner" "$suite/$1.rq" "$suite/exists01.ttl" "$suite/$1.srx"; then
    failed=$((failed + 1))
  fi
}
run_named() {
  total=$((total + 1))
  base="http://www.w3.org/2009/sparql/docs/tests/data-sparql11/exists/"
  if ! "$runner" --named "$suite/exists03.rq" "$suite/exists03.srx" "$base" \
    "$base"exists02.ttl "$suite/exists02.ttl"; then
    failed=$((failed + 1))
  fi
}
run_graph_variable() {
  total=$((total + 1))
  base="http://www.w3.org/2009/sparql/docs/tests/data-sparql11/exists/"
  document="$base"exists-graph-variable.ttl
  if ! "$runner" --mixed "$suite/exists-graph-variable.rq" "$suite/exists-graph-variable.srx" "$base" \
    "$document" "$suite/exists-graph-variable.ttl" "$document" "$suite/exists-graph-variable.ttl"; then
    failed=$((failed + 1))
  fi
}

for name in exists01 exists02 exists04 exists05
do
  run_default "$name"
done
run_named
run_graph_variable

printf '%s\n' "W3C SPARQL M4 EXISTS manifest: total=$total failed=$failed"
[ "$total" -eq 6 ]
[ "$failed" -eq 0 ]
