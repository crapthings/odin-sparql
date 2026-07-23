#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M3_SUITE:-}" ]; then
  suite=$W3C_M3_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
run_case() {
	total=$((total + 1))
	if ! "$runner" "$1" "$2" "$3"; then
		failed=$((failed + 1))
	fi
}

run_mixed_case() {
	total=$((total + 1))
	if ! "$runner" --mixed "$@"; then
		failed=$((failed + 1))
	fi
}

optional="$suite/sparql10/optional"
run_case "$optional/q-opt-1.rq" "$optional/data.ttl" "$optional/result-opt-1.ttl"
run_case "$optional/q-opt-2.rq" "$optional/data.ttl" "$optional/result-opt-2.ttl"
run_case "$optional/q-opt-3.rq" "$optional/data.ttl" "$optional/result-opt-3.ttl"
run_case "$optional/q-opt-complex-1.rq" "$optional/complex-data-1.ttl" "$optional/result-opt-complex-1.ttl"
optional_base="http://www.w3.org/2001/sw/DataAccess/tests/data-r2/optional/"
for name in 2 3
do
	run_mixed_case "$optional/q-opt-complex-$name.rq" "$optional/result-opt-complex-$name.ttl" "$optional_base" \
	  "$optional_base"complex-data-2.ttl "$optional/complex-data-2.ttl" \
	  "$optional_base"complex-data-1.ttl "$optional/complex-data-1.ttl"
done

negation="$suite/sparql11/negation"
run_case "$negation/full-minuend.rq" "$negation/full-minuend.ttl" "$negation/full-minuend.srx"
run_case "$negation/part-minuend.rq" "$negation/part-minuend.ttl" "$negation/part-minuend.srx"

bind="$suite/sparql11/bind"
run_case "$bind/bind01.rq" "$bind/data.ttl" "$bind/bind01.srx"
run_case "$bind/bind02.rq" "$bind/data.ttl" "$bind/bind02.srx"
run_case "$bind/bind03.rq" "$bind/data.ttl" "$bind/bind03.srx"
run_case "$bind/bind04.rq" "$bind/data.ttl" "$bind/bind04.srx"
run_case "$bind/bind05.rq" "$bind/data.ttl" "$bind/bind05.srx"
run_case "$bind/bind06.rq" "$bind/data.ttl" "$bind/bind06.srx"
run_case "$bind/bind07.rq" "$bind/data.ttl" "$bind/bind07.srx"
run_case "$bind/bind08.rq" "$bind/data.ttl" "$bind/bind08.srx"
run_case "$bind/bind10.rq" "$bind/data.ttl" "$bind/bind10.srx"
run_case "$bind/bind11.rq" "$bind/data.ttl" "$bind/bind11.srx"

graph="$suite/sparql10/graph"
graph_base="http://www.w3.org/2001/sw/DataAccess/tests/data-r2/graph/"
total=$((total + 1))
if ! "$runner" --base "$graph_base" "$graph/graph-01.rq" "$graph/data-g1.ttl" "$graph/graph-01.ttl"; then
  failed=$((failed + 1))
fi
total=$((total + 1))
if ! "$runner" --named "$graph/graph-03.rq" "$graph/graph-03.ttl" \
  "$graph_base" "$graph_base"data-g1.ttl "$graph/data-g1.ttl"; then
  failed=$((failed + 1))
fi
for name in graph-02 graph-variable-join graph-optional
do
  total=$((total + 1))
  case "$name" in
    graph-02)
      if ! "$runner" --named "$graph/$name.rq" "$graph/$name.ttl" "$graph_base" \
        "$graph_base"data-g1.ttl "$graph/data-g1.ttl"; then failed=$((failed + 1)); fi
      ;;
    graph-variable-join)
      if ! "$runner" --named "$graph/$name.rq" "$graph/$name.ttl" "$graph_base" \
        "$graph_base"data-variable-join.ttl "$graph/data-variable-join.ttl" \
        "$graph_base"data-g1.ttl "$graph/data-g1.ttl"; then failed=$((failed + 1)); fi
      ;;
    graph-optional)
      if ! "$runner" --named "$graph/$name.rq" "$graph/$name.ttl" "$graph_base" \
        "$graph_base"data-optional.ttl "$graph/data-optional.ttl" \
        "$graph_base"data-g1.ttl "$graph/data-g1.ttl"; then failed=$((failed + 1)); fi
      ;;
  esac
done
run_case "$graph/graph-04.rq" "$graph/data-g1.ttl" "$graph/graph-04.ttl"
for name in graph-05 graph-06 graph-07 graph-08
do
	run_mixed_case "$graph/$name.rq" "$graph/$name.ttl" "$graph_base" \
	  "$graph_base"data-g1.ttl "$graph/data-g1.ttl" \
	  "$graph_base"data-g2.ttl "$graph/data-g2.ttl"
done
run_mixed_case "$graph/graph-09.rq" "$graph/graph-09.ttl" "$graph_base" \
  "$graph_base"data-g3.ttl "$graph/data-g3.ttl" \
  "$graph_base"data-g4.ttl "$graph/data-g4.ttl"
run_mixed_case "$graph/graph-10.rq" "$graph/graph-10.ttl" "$graph_base" \
  "$graph_base"data-g3.ttl "$graph/data-g3.ttl" \
  "$graph_base"data-g3-dup.ttl "$graph/data-g3-dup.ttl"
run_mixed_case "$graph/graph-11.rq" "$graph/graph-11.ttl" "$graph_base" \
  "$graph_base"data-g1.ttl "$graph/data-g1.ttl" \
  "$graph_base"data-g1.ttl "$graph/data-g1.ttl" \
  "$graph_base"data-g2.ttl "$graph/data-g2.ttl" \
  "$graph_base"data-g3.ttl "$graph/data-g3.ttl" \
  "$graph_base"data-g4.ttl "$graph/data-g4.ttl"
for name in graph-empty graph-empty-exist graph-empty-not-exist graph-variable-scope
do
	run_mixed_case "$graph/$name.rq" "$graph/$name.ttl" "$graph_base" \
	  "$graph_base"data-g1.ttl "$graph/data-g1.ttl" \
	  "$graph_base"data-g1.ttl "$graph/data-g1.ttl" \
	  "$graph_base"data-g2.ttl "$graph/data-g2.ttl"
done

equals="$suite/sparql10/expr-equals"
run_case "$equals/query-eq-3.rq" "$equals/data-eq.ttl" "$equals/result-eq-3.ttl"
run_case "$equals/query-eq-4.rq" "$equals/data-eq.ttl" "$equals/result-eq-4.ttl"
run_case "$equals/query-eq-5.rq" "$equals/data-eq.ttl" "$equals/result-eq-5.ttl"

dataset="$suite/sparql10/dataset"
dataset_base="http://www.w3.org/2001/sw/DataAccess/tests/data-r2/dataset/"
graph_one="$dataset_base"data-g1.ttl
graph_two="$dataset_base"data-g2.ttl
for name in 01 02 03 04
do
  total=$((total + 1))
  if ! "$runner" --named "$dataset/dataset-$name.rq" "$dataset/dataset-$name.ttl" "$dataset_base" \
    "$graph_one" "$dataset/data-g1.ttl"; then
    failed=$((failed + 1))
  fi
done
for name in 05 06 07 08
do
  total=$((total + 1))
  if ! "$runner" --named "$dataset/dataset-$name.rq" "$dataset/dataset-$name.ttl" "$dataset_base" \
    "$graph_one" "$dataset/data-g1.ttl" "$graph_two" "$dataset/data-g2.ttl"; then
    failed=$((failed + 1))
  fi
done
for name in 09b 10b
do
  total=$((total + 1))
  if ! "$runner" --named "$dataset/dataset-$name.rq" "$dataset/dataset-${name%b}.ttl" "$dataset_base" \
    "$dataset_base"data-g3-dup.ttl "$dataset/data-g3-dup.ttl" \
    "$dataset_base"data-g3.ttl "$dataset/data-g3.ttl"; then
    failed=$((failed + 1))
  fi
done
total=$((total + 1))
if ! "$runner" --named "$dataset/dataset-11.rq" "$dataset/dataset-11.ttl" "$dataset_base" \
  "$dataset_base"data-g1.ttl "$dataset/data-g1.ttl" \
  "$dataset_base"data-g2.ttl "$dataset/data-g2.ttl" \
  "$dataset_base"data-g3.ttl "$dataset/data-g3.ttl" \
  "$dataset_base"data-g4.ttl "$dataset/data-g4.ttl"; then
  failed=$((failed + 1))
fi
total=$((total + 1))
if ! "$runner" --named "$dataset/dataset-12b.rq" "$dataset/dataset-12.ttl" "$dataset_base" \
  "$dataset_base"data-g1-dup.ttl "$dataset/data-g1-dup.ttl" \
  "$dataset_base"data-g2-dup.ttl "$dataset/data-g2-dup.ttl" \
  "$dataset_base"data-g3-dup.ttl "$dataset/data-g3-dup.ttl" \
  "$dataset_base"data-g4-dup.ttl "$dataset/data-g4-dup.ttl" \
  "$dataset_base"data-g1.ttl "$dataset/data-g1.ttl" \
  "$dataset_base"data-g2.ttl "$dataset/data-g2.ttl" \
  "$dataset_base"data-g3.ttl "$dataset/data-g3.ttl" \
  "$dataset_base"data-g4.ttl "$dataset/data-g4.ttl"; then
  failed=$((failed + 1))
fi

printf '%s\n' "W3C SPARQL M3 graph-pattern subset: total=$total failed=$failed"
[ "$total" -eq 50 ]
[ "$failed" -eq 0 ]
