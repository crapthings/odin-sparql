#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_BNODE_COREFERENCE_SUITE:-}" ]; then
  suite=$W3C_BNODE_COREFERENCE_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/bnode-coreference"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=1
failed=0
if ! "$runner" "$suite/query.rq" "$suite/data.ttl" "$suite/result.ttl"; then
  failed=1
fi

printf '%s\n' "W3C SPARQL blank-node coreference: total=$total failed=$failed"
[ "$failed" -eq 0 ]
