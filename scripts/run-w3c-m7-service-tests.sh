#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M7_SERVICE_SUITE:-}" ]; then
  suite=$W3C_M7_SERVICE_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/service"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  name=$1
  data=$2
  expected=$3
  shift 3
  if ! "$runner" --service "$suite/$name.rq" "$data" "$suite/$expected.srx" "$@"; then
    failed=$((failed + 1))
  fi
}

run_case service01 "$suite/data01.ttl" service01 http://example.org/sparql "$suite/data01endpoint.ttl"
run_case service02 - service02 http://example1.org/sparql "$suite/data02endpoint1.ttl" http://example2.org/sparql "$suite/data02endpoint2.ttl"
run_case service03 - service03 http://example1.org/sparql "$suite/data03endpoint1.ttl" http://example2.org/sparql "$suite/data03endpoint2.ttl"
run_case service04a "$suite/data04.ttl" service04 http://example.org/sparql "$suite/data04endpoint.ttl"
run_case service05 "$suite/data05.ttl" service05 http://example1.org/sparql "$suite/data05endpoint1.ttl" http://example2.org/sparql "$suite/data05endpoint2.ttl"
run_case service06 - service06 http://example1.org/sparql "$suite/data06endpoint1.ttl"
run_case service07 "$suite/data07.ttl" service07

printf '%s\n' "W3C SPARQL M7 SERVICE: total=$total failed=$failed"
[ "$total" -eq 7 ]
[ "$failed" -eq 0 ]
