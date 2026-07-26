#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_PROJECT_EXPRESSION_SUITE:-}" ]; then
  suite=$W3C_M4_PROJECT_EXPRESSION_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/project-expression"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in projexp01 projexp02 projexp03 projexp04 projexp05 projexp06 projexp07
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/$name.ttl" "$suite/$name.srx"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 project expressions: total=$total failed=$failed"
[ "$total" -eq 7 ]
[ "$failed" -eq 0 ]
