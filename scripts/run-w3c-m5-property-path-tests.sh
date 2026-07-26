#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M5_PROPERTY_PATH_SUITE:-}" ]; then
  suite=$W3C_M5_PROPERTY_PATH_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/property-path"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_with() {
  total=$((total + 1))
  if ! "$runner" "$suite/$1" "$suite/$2" "$suite/$3"; then
    failed=$((failed + 1))
  fi
}
run_case() { run_with "$1.rq" "$1.ttl" "$1.srx"; }

run_case pp01
run_case pp08
run_case pp09
run_case path-p1
run_case path-p3
run_case pp10
run_case pp14
run_case pp37
run_case pp05
run_case pp13
run_case nps_a
run_case nps_inverse
run_case nps_direct_and_inverse

# Additional manifest cases that exercise closure, sequence and alternative
# multiplicity, fixed endpoints, VALUES, and the empty-graph identity cases.
run_with pp02.rq pp01.ttl pp02.srx
run_case pp03
run_case pp11
run_with pp12.rq pp11.ttl pp12.srx
run_with pp14.rq pp16.ttl pp16.srx
run_with path-2-2.rq data-diamond.ttl diamond-2.srx
run_with path-2-2.rq data-diamond-tail.ttl diamond-tail-2.srx
run_with path-2-2.rq data-diamond-loop.ttl diamond-loop-2.srx
run_with path-3-3.rq data-diamond-loop.ttl diamond-loop-5a.srx
run_with path-p2.rq path-p1.ttl path-p2.srx
run_with path-p4.rq path-p3.ttl path-p4.srx
run_with pp36.rq clique3.ttl pp36.srx
run_with values_and_path.rq empty.ttl values_and_path.srx
run_case nps_a_inverse
run_with zero_or_more_set_start.rq empty.ttl zero_or_more_set_start.srx
run_with zero_or_more_set_end.rq empty.ttl zero_or_more_set_end.srx
run_with zero_or_one_set_start.rq empty.ttl zero_or_one_set_start.srx
run_with zero_or_one_set_end.rq empty.ttl zero_or_one_set_end.srx

# Named-graph cases must retain each graph's own path scope: the two partial
# paths in pp06 cannot be joined across graphs, while pp07 can match inside
# its single named graph.
suite_abs=$(cd "$suite" && pwd)
suite_base="file://$suite_abs/"
run_named_ng_case() {
  total=$((total + 1))
  if ! "$runner" --named "$suite_abs/$1" "$suite_abs/$2" "$suite_base" \
    "${suite_base}ng-01.ttl" "$suite_abs/ng-01.ttl" \
    "${suite_base}ng-02.ttl" "$suite_abs/ng-02.ttl" \
    "${suite_base}ng-03.ttl" "$suite_abs/ng-03.ttl"; then
    failed=$((failed + 1))
  fi
}
run_named_ng_case path-ng-01.rq path-ng-01.srx
run_named_ng_case path-ng-02.rq path-ng-01.srx

total=$((total + 1))
if ! "$runner" --named "$suite_abs/pp06.rq" "$suite_abs/pp06.srx" "$suite_base" \
  "${suite_base}pp061.ttl" "$suite_abs/pp061.ttl" \
  "${suite_base}pp062.ttl" "$suite_abs/pp062.ttl"; then
  failed=$((failed + 1))
fi
total=$((total + 1))
if ! "$runner" --named "$suite_abs/pp06.rq" "$suite_abs/pp07.srx" "$suite_base" \
  "${suite_base}pp07.ttl" "$suite_abs/pp07.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL M5 property-path gate: total=$total failed=$failed"
[ "$total" -eq 35 ]
[ "$failed" -eq 0 ]
