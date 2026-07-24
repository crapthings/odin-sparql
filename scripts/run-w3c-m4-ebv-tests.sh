#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_EBV_SUITE:-}" ]; then
  suite=$W3C_M4_EBV_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/boolean-effective-value"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in boolean-literal bev-1 bev-2 bev-3 bev-4 bev-5 bev-6
do
  case "$name" in
    bev-5|bev-6) data=data-2.ttl ;;
    *) data=data-1.ttl ;;
  esac
  total=$((total + 1))
  if ! "$runner" "$suite/query-$name.rq" "$suite/$data" "$suite/result-$name.ttl"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 effective boolean value: total=$total failed=$failed"
[ "$total" -eq 7 ]
[ "$failed" -eq 0 ]
