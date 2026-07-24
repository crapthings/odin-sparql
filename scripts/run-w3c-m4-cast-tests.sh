#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_CAST_SUITE:-}" ]; then
  suite=$W3C_M4_CAST_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/cast"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in int dec bool str flt dbl
do
  total=$((total + 1))
  if ! "$runner" "$suite/cast-$name.rq" "$suite/data.ttl" "$suite/cast-$name.srx"; then
    failed=$((failed + 1))
  fi
done

total=$((total + 1))
if ! "$runner" "$suite/cast-dT.rq" "$suite/data.ttl" "$suite/cast-dT.srx"; then
	failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL M4 cast subset: total=$total failed=$failed"
[ "$total" -eq 7 ]
[ "$failed" -eq 0 ]
