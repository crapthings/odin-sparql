#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_ORDER_SUITE:-}" ]; then
  suite=$W3C_M4_ORDER_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/sort"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for number in 1 2 3 4 5 6 7 8 9 10
do
  total=$((total + 1))
  result="$suite/result-sort-$number.rdf"
  case "$number" in
    1) query="$suite/query-sort-1.rq"; data="$suite/data-sort-1.ttl" ;;
    2) query="$suite/query-sort-2.rq"; data="$suite/data-sort-1.ttl" ;;
    3) query="$suite/query-sort-3.rq"; data="$suite/data-sort-3.ttl" ;;
    4) query="$suite/query-sort-4.rq"; data="$suite/data-sort-4.ttl" ;;
    5) query="$suite/query-sort-5.rq"; data="$suite/data-sort-4.ttl" ;;
    6) query="$suite/query-sort-6.rq"; data="$suite/data-sort-6.ttl" ;;
    7) query="$suite/query-sort-4.rq"; data="$suite/data-sort-7.ttl" ;;
    8) query="$suite/query-sort-4.rq"; data="$suite/data-sort-8.ttl" ;;
    9) query="$suite/query-sort-9.rq"; data="$suite/data-sort-9.ttl" ;;
    10) query="$suite/query-sort-10.rq"; data="$suite/data-sort-9.ttl" ;;
  esac
  if ! "$runner" --ordered "$query" "$data" "$result"; then
    failed=$((failed + 1))
  fi
done

for name in numbers builtin function not-projected
do
  total=$((total + 1))
  case "$name" in
    numbers) query="$suite/query-sort-numbers.rq" ;;
    builtin) query="$suite/query-sort-builtin.rq" ;;
    function) query="$suite/query-sort-function.rq" ;;
    not-projected) query="$suite/sort-not-projected.rq" ;;
  esac
  if ! "$runner" --ordered "$query" "$suite/data-sort-$name.ttl" "$suite/result-sort-$name.ttl"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 ORDER BY subset: total=$total failed=$failed"
[ "$total" -eq 14 ]
[ "$failed" -eq 0 ]
