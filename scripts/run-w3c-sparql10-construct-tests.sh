#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_SPARQL10_CONSTRUCT_SUITE:-}" ]; then
  suite=$W3C_SPARQL10_CONSTRUCT_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/construct"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" --base "http://example/" "$suite/$1.rq" "$suite/$2.ttl" "$suite/$3.ttl"; then
    failed=$((failed + 1))
  fi
}

run_case query-ident data-ident result-ident
run_case query-subgraph data-ident result-subgraph
run_case query-reif-1 data-reif result-reif
run_case query-reif-2 data-reif result-reif
run_case query-construct-optional data-opt result-construct-optional

printf '%s\n' "W3C SPARQL 1.0 CONSTRUCT: total=$total failed=$failed"
[ "$total" -eq 5 ]
[ "$failed" -eq 0 ]
