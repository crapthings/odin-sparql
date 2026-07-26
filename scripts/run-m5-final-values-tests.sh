#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
fixtures="$root/tests/final_values"
runner="$root/.cache/odin-sparql-basic-runner"

if [ ! -d "$odin_rdf" ]; then
  printf '%s\n' 'ODIN_RDF_COLLECTION must name an odin-rdf checkout' >&2
  exit 2
fi

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$fixtures/$1.rq" "$fixtures/data.ttl" "$fixtures/$1.srx"; then
    failed=$((failed + 1))
  fi
}

run_case aggregate-having
run_case select-expression
run_case ask-aggregate-having
run_case subquery-aggregate-having

printf '%s\n' "M5 query-level final VALUES semantics gate: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
