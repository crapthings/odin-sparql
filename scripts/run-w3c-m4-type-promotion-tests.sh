#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_TYPE_PROMOTION_SUITE:-}" ]; then
  suite=$W3C_M4_TYPE_PROMOTION_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/type-promotion"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in \
  tP-byte-short \
  tP-decimal-decimal \
  tP-double-decimal \
  tP-double-double \
  tP-double-float \
  tP-float-decimal \
  tP-float-float \
  tP-int-short \
  tP-integer-short \
  tP-long-short \
  tP-negativeInteger-short \
  tP-nonNegativeInteger-short \
  tP-nonPositiveInteger-short \
  tP-positiveInteger-short \
  tP-short-decimal \
  tP-short-double \
  tP-short-float \
  tP-short-short \
  tP-unsignedByte-short \
  tP-unsignedInt-short \
  tP-unsignedLong-short \
  tP-unsignedShort-short
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/tP.ttl" "$suite/true.ttl"; then
    failed=$((failed + 1))
  fi
done

for name in \
  tP-byte-short-fail \
  tP-double-decimal-fail \
  tP-double-float-fail \
  tP-float-decimal-fail \
  tP-short-byte-fail \
  tP-short-int-fail \
  tP-short-long-fail \
  tP-short-short-fail
do
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/tP.ttl" "$suite/false.ttl"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 type-promotion: total=$total failed=$failed"
[ "$total" -eq 30 ]
[ "$failed" -eq 0 ]
