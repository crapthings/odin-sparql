#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_EXPRESSION_SUITE:-}" ]; then
  suite=$W3C_M4_EXPRESSION_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/expr-equals"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in 1 2 3 4 5 bool float
do
  total=$((total + 1))
  data="$suite/data-eq.ttl"
  case "$name" in
    bool) data="$suite/data-eq-bool.ttl" ;;
    float) data="$suite/data-eq-float.ttl" ;;
  esac
  if ! "$runner" "$suite/query-eq-$name.rq" "$data" "$suite/result-eq-$name.ttl"; then
    failed=$((failed + 1))
  fi
done

total=$((total + 1))
if ! "$runner" "$suite/query-eq-dateTime.rq" "$suite/data-eq-dateTime.ttl" "$suite/result-eq-dateTime.ttl"; then
	failed=$((failed + 1))
fi

# The pinned `eq-2-2` manifest action intentionally references the same query
# and expected result as `eq-2-1`; execute both official entries verbatim.
for entry in eq-2-1 eq-2-2
do
	total=$((total + 1))
	if ! "$runner" "$suite/query-eq2-1.rq" "$suite/data-eq.ttl" "$suite/result-eq2-1.ttl"; then
		failed=$((failed + 1))
	fi
done

for name in 1 2 3 4 5
do
	total=$((total + 1))
	if ! "$runner" "$suite/query-eq-graph-$name.rq" "$suite/data-eq.ttl" "$suite/result-eq-graph-$name.ttl"; then
		failed=$((failed + 1))
	fi
done

printf '%s\n' "W3C SPARQL M4 value-equality manifest: total=$total failed=$failed"
[ "$total" -eq 15 ]
[ "$failed" -eq 0 ]
