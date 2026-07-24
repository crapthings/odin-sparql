#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_CASE_SUITE:-}" ]; then
  suite=$W3C_M4_CASE_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/functions"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$suite/$1.rq" "$suite/$2.ttl" "$suite/$3.srx"; then
    failed=$((failed + 1))
  fi
}

run_case lcase01 data lcase01
run_case ucase01 data ucase01
run_case lcase01 data5 lcase01-non-bmp
run_case ucase01 data5 ucase01-non-bmp

printf '%s\n' "W3C SPARQL M4 Unicode case functions: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
