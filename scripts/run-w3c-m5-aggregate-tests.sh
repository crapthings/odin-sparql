#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M5_AGGREGATES_SUITE:-}" ]; then
  suite=$W3C_M5_AGGREGATES_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/aggregates"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"
result_base="file://$(CDPATH= cd -- "$suite" && pwd)/"

total=0
failed=0
run_case() {
	total=$((total + 1))
	if ! "$runner" "$suite/$1.rq" "$suite/$2" "$suite/$3"; then
		failed=$((failed + 1))
	fi
}

run_json_case() {
	total=$((total + 1))
	if ! "$runner" --json "$suite/$1.rq" "$suite/$2" "$suite/$3"; then
		failed=$((failed + 1))
	fi
}

run_named_case() {
	total=$((total + 1))
	if ! "$runner" --named "$suite/$1.rq" "$suite/$2" "$result_base" "${result_base}singleton.ttl" "$suite/singleton.ttl" "${result_base}pair.ttl" "$suite/pair.ttl"; then
		failed=$((failed + 1))
	fi
}

for name in agg01 agg02 agg03 agg04 agg05 agg06 agg07
do
  run_case "$name" agg01.ttl "$name.srx"
done
run_case agg-count-distinct agg-numeric-duplicates.ttl agg-count-distinct.srx
run_case agg-count-rows-distinct agg-numeric-duplicates.ttl agg-count-rows-distinct.srx

run_case agg-sum-01 agg-numeric.ttl agg-sum-01.srx
run_case agg-sum-distinct agg-numeric-duplicates.ttl agg-sum-distinct.srx
run_case agg-avg-01 agg-numeric.ttl agg-avg-01.srx
run_case agg-avg-03 empty.ttl agg-avg-03.srx
run_case agg-avg-distinct agg-numeric-duplicates.ttl agg-avg-distinct.srx

run_case agg-min-01 agg-numeric.ttl agg-min-01.srx
run_case agg-min-02 agg-numeric.ttl agg-min-02.srx
run_case agg-min-distinct agg-numeric-duplicates.ttl agg-min-distinct.srx
run_case agg-max-01 agg-numeric.ttl agg-max-01.srx
run_case agg-max-02 agg-numeric.ttl agg-max-02.srx
run_case agg-max-distinct agg-numeric-duplicates.ttl agg-max-distinct.srx
run_case agg-sample-01 agg-numeric.ttl agg-sample-01.srx
run_case agg-sample-distinct agg-numeric-duplicates.ttl agg-sample-01.srx
run_case agg-err-01 agg-err-01.ttl agg-err-01.srx
run_case agg-empty-group-max-1 empty.ttl agg-empty-group-max-1.srx
run_case agg-empty-group-max-2 empty.ttl agg-empty-group-max-2.srx
run_json_case agg-empty-group-count-1 empty.ttl agg-empty-group-count-1.srj
run_json_case agg-empty-group-count-2 empty.ttl agg-empty-group-count-2.srj
run_named_case agg-empty-group-count-graph agg-empty-group-count-graph.ttl
run_case agg-multiple-having agg-numeric.ttl agg-multiple-having.srx
run_case agg-group-fn agg-numeric.ttl agg-group-fn.srx
run_case agg-group-builtin agg-numeric.ttl agg-group-builtin.srx

run_case agg-groupconcat-1 agg-groupconcat-1.ttl agg-groupconcat-1.srx
run_case agg-groupconcat-2 agg-groupconcat-1.ttl agg-groupconcat-2.srx
run_case agg-groupconcat-3 agg-groupconcat-1.ttl agg-groupconcat-3.srx
run_case agg-groupconcat-4 empty.ttl agg-groupconcat-4.srx
run_case agg-groupconcat-5 empty.ttl agg-groupconcat-5.srx
run_case agg-groupconcat-6 empty.ttl agg-groupconcat-6.srx
run_case agg-groupconcat-distinct empty.ttl agg-groupconcat-distinct.srx

printf '%s\n' "W3C SPARQL M5 aggregate subset: total=$total failed=$failed"
[ "$total" -eq 38 ]
[ "$failed" -eq 0 ]
