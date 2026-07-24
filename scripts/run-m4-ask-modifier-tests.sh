#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
fixtures="$root/tests/ask_modifiers"
runner="$root/.cache/odin-sparql-basic-runner"

if [ ! -d "$odin_rdf" ]; then
  printf '%s\n' 'ODIN_RDF_COLLECTION must name an odin-rdf checkout' >&2
  exit 2
fi

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$fixtures/$1.rq" "$fixtures/data.ttl" "$fixtures/$1.srx"; then
    failed=$((failed + 1))
  fi
}

run_case offset-true
run_case offset-false
run_case group-having-true
run_case group-having-false
run_case limit-zero

printf '%s\n' "M4 ASK solution modifier gate: total=$total failed=$failed"
[ "$total" -eq 5 ]
[ "$failed" -eq 0 ]
