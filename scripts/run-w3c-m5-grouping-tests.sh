#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M5_GROUPING_SUITE:-}" ]; then
  suite=$W3C_M5_GROUPING_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/grouping"
fi
runner="$root/.cache/odin-sparql-basic-runner"
syntax_runner="$root/.cache/odin-sparql-syntax-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"
odin build "$root/tests/w3c/syntax_runner" -out:"$syntax_runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_evaluation() {
  total=$((total + 1))
  if ! "$runner" "$suite/$1.rq" "$suite/$2.ttl" "$suite/$1.srx"; then
    failed=$((failed + 1))
  fi
}
run_syntax() {
  total=$((total + 1))
  if ! "$syntax_runner" negative "$suite/$1.rq"; then
    failed=$((failed + 1))
  fi
}

for name in group01 group03 group04
do
  run_evaluation "$name" group-data-1
done
run_evaluation group05 group-data-2
run_syntax group06
run_syntax group07

printf '%s\n' "W3C SPARQL M5 grouping manifest: total=$total failed=$failed"
[ "$total" -eq 6 ]
[ "$failed" -eq 0 ]
