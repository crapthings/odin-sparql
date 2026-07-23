#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
runner="$root/.cache/odin-sparql-basic-runner"
fixtures="$root/tests/describe_policy"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" "$fixtures/$1.rq" "$fixtures/data.ttl" "$fixtures/${1}-result.ttl"; then
    failed=$((failed + 1))
  fi
}

run_case direct
run_case explicit-empty-where
run_case variable
run_case star

run_modifier_case() {
  total=$((total + 1))
  if ! "$runner" "$fixtures/modifier-$1.rq" "$fixtures/modifier-data.ttl" "$fixtures/modifier-$1-result.ttl"; then
    failed=$((failed + 1))
  fi
}

run_modifier_case limit
run_modifier_case offset
run_modifier_case explicit

run_group_case() {
  total=$((total + 1))
  if ! "$runner" "$fixtures/group-$1.rq" "$fixtures/group-data.ttl" "$fixtures/group-$1-result.ttl"; then
    failed=$((failed + 1))
  fi
}

run_group_case having
run_group_case order-limit
run_group_case final-values

# This case uses FROM to promote an application-owned named graph into the
# active default graph; the variable target itself is a blank node.
total=$((total + 1))
if ! "$runner" --named "$fixtures/from-variable-blank.rq" "$fixtures/from-variable-blank-result.ttl" "urn:base/" "urn:source" "$fixtures/from-variable-blank-data.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "M6 DESCRIBE policy: total=$total failed=$failed"
[ "$total" -eq 11 ]
[ "$failed" -eq 0 ]
