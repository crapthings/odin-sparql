#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M6_CSV_TSV_RESULT_SUITE:-}" ]; then
  suite=$W3C_M6_CSV_TSV_RESULT_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/csv-tsv-res"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for format in csv tsv
do
  for name in 01 02 03
  do
    total=$((total + 1))
    query="$suite/csvtsv$name.rq"
    data="$suite/data.ttl"
    if [ "$name" = 03 ]; then query="$suite/csvtsv01.rq"; data="$suite/data2.ttl"; fi
    if ! "$runner" "--$format" "$query" "$data" "$suite/csvtsv$name.$format"; then
      failed=$((failed + 1))
    fi
  done
done

printf '%s\n' "W3C SPARQL M6 CSV/TSV results: total=$total failed=$failed"
[ "$total" -eq 6 ]
[ "$failed" -eq 0 ]
