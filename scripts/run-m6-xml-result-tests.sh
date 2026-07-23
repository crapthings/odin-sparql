#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
fixtures="$root/tests/xml_results"
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
  if ! "$runner" --xml "$fixtures/$1.rq" "$fixtures/data.ttl" "$fixtures/$1.srx"; then
    failed=$((failed + 1))
  fi
}

run_case select
run_case ask-true
run_case ask-false

printf '%s\n' "M6 SPARQL Results XML gate: total=$total failed=$failed"
[ "$total" -eq 3 ]
[ "$failed" -eq 0 ]
