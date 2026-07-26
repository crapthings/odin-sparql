#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_OPEN_WORLD_SUITE:-}" ]; then
  suite=$W3C_M4_OPEN_WORLD_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/open-world"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in open-eq-01 open-eq-02 open-eq-03 open-eq-04 open-eq-05 open-eq-06
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/data-1.ttl" "$suite/$name-result.srx"; then
    failed=$((failed + 1))
  fi
done
for name in open-eq-07 open-eq-08 open-eq-09 open-eq-10 open-eq-11 open-eq-12
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/data-2.ttl" "$suite/$name-result.srx"; then
    failed=$((failed + 1))
  fi
done
for name in open-cmp-01 open-cmp-02
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/data-4.ttl" "$suite/$name-result.srx"; then
    failed=$((failed + 1))
  fi
done
for name in date-1 date-2 date-3 date-4
do
	total=$((total + 1))
	if ! "$runner" "$suite/$name.rq" "$suite/data-3.ttl" "$suite/$name-result.srx"; then
		failed=$((failed + 1))
	fi
done

printf '%s\n' "W3C SPARQL M4 open-world subset: total=$total failed=$failed"
[ "$total" -eq 18 ]
[ "$failed" -eq 0 ]
