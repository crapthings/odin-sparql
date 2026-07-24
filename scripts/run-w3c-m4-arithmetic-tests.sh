#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_ARITHMETIC_SUITE:-}" ]; then
  suite=$W3C_M4_ARITHMETIC_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/expr-ops"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in plus-1 minus-1 mul-1 add-numbers-cast subtract-numbers-cast multiply-numbers-cast divide-numbers-cast add-literals
do
  total=$((total + 1))
  data="$suite/data.ttl"
  if [ "$name" = add-numbers-cast ] || [ "$name" = subtract-numbers-cast ] || [ "$name" = multiply-numbers-cast ] || [ "$name" = divide-numbers-cast ]; then
    data="$suite/data-numbers.ttl"
  fi
  if [ "$name" = add-literals ]; then data=/dev/null; fi
  runner_flag=""
  case "$name" in
    add-numbers-cast|subtract-numbers-cast|multiply-numbers-cast|divide-numbers-cast)
      runner_flag="--decimal-equivalent"
      ;;
  esac
  if ! "$runner" ${runner_flag:+"$runner_flag"} "$suite/query-$name.rq" "$data" "$suite/result-$name.srx"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 arithmetic manifest entries: total=$total failed=$failed"
[ "$total" -eq 8 ]
[ "$failed" -eq 0 ]
