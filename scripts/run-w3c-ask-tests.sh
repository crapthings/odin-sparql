#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_ASK_SUITE:-}" ]; then
  suite=$W3C_ASK_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/ask"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in ask-1 ask-4 ask-7 ask-8
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/data.ttl" "$suite/$name.srx"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL ASK subset: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
