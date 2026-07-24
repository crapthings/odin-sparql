#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
fixtures="$root/tests/graph_results"
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
  if ! "$runner" "$1" "$fixtures/$2.rq" "$fixtures/data.ttl" "$fixtures/$2.$3"; then
    failed=$((failed + 1))
  fi
}

run_case --ntriples construct nt
run_case --turtle construct ttl
run_case --ntriples describe nt
run_case --turtle describe ttl

printf '%s\n' "M6 graph result serialization gate: total=$total failed=$failed"
[ "$total" -eq 4 ]
[ "$failed" -eq 0 ]
