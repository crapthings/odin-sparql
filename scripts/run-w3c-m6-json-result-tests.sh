#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M6_JSON_RESULT_SUITE:-}" ]; then
  suite=$W3C_M6_JSON_RESULT_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/json-res"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in jsonres01 jsonres02 jsonres03 jsonres04
do
  total=$((total + 1))
  if ! "$runner" --json "$suite/$name.rq" "$suite/data.ttl" "$suite/$name.srj"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M6 JSON results: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
