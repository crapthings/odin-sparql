#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_VALUES_SUITE:-}" ]; then
  suite=$W3C_VALUES_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/bindings"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in values01 values02 values03 values04 values05 values06 values07 values08
do
  number=${name#values}
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/data$number.ttl" "$suite/$name.srx"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL 1.1 VALUES subset: total=$total failed=$failed"
[ "$total" -eq 8 ]
[ "$failed" -eq 0 ]
