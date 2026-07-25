#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
w3c_root=${W3C_TEST_ROOT:-"$root/../odin-rdf/.cache/w3c-rdf-tests-d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86"}

if [ ! -d "$odin_rdf" ]; then
  printf '%s\n' 'ODIN_RDF_COLLECTION must name an odin-rdf checkout' >&2
  exit 2
fi
if [ ! -d "$odin_graph" ]; then
  printf '%s\n' 'ODIN_GRAPH_COLLECTION must name an odin-graph checkout' >&2
  exit 2
fi
if [ ! -f "$w3c_root/sparql/sparql11/syntax-query/manifest.ttl" ]; then
  printf '%s\n' 'W3C_TEST_ROOT must name the pinned w3c/rdf-tests checkout; development conformance verification never downloads fixtures' >&2
  exit 2
fi

sh "$root/scripts/check-release-facts.sh"

odin check "$root/sparql" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/sparql/internal/lexer" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/sparql/dataset" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/sparql/graph_dataset" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph" -collection:odin-sparql="$root"
odin check "$root/sparql/results" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/benchmarks/bgp" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/examples/minimal" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin check "$root/examples/custom_view" -no-entry-point -vet -warnings-as-errors -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

odin test "$root/sparql" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/internal/lexer" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/results" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/algebra" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/eval" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/engine" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
# The evaluator and public engine contain the result-lifetime boundaries for
# grouping, ordering, and result materialization. Keep a focused sanitizer
# pass in the offline development evidence; CI still provides the full matrix.
odin test "$root/sparql/eval" -sanitize:address -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/engine" -sanitize:address -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
# Optimized execution uses different temporary-allocation lifetimes. Use
# separate modules so this remains a practical offline gate on constrained
# machines; each module still uses -o:speed code generation.
odin test "$root/sparql/engine" -o:speed -use-separate-modules -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/tests/public_parser" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/tests/public_engine" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/tests/dataset" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin test "$root/sparql/graph_dataset" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph" -collection:odin-sparql="$root"
odin test "$root/tests/property" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin run "$root/examples/minimal" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin run "$root/examples/custom_view" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin run "$root/tests/fuzz" -o:speed -define:FUZZ_CASES=50000 -define:FUZZ_MAX_BYTES=512 -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_SYNTAX_SUITE="$w3c_root/sparql/sparql11/syntax-query" sh "$root/scripts/run-w3c-syntax-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_BASIC_SUITE="$w3c_root/sparql/sparql10/basic" sh "$root/scripts/run-w3c-basic-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_TRIPLE_MATCH_SUITE="$w3c_root/sparql/sparql10/triple-match" sh "$root/scripts/run-w3c-triple-match-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_BNODE_COREFERENCE_SUITE="$w3c_root/sparql/sparql10/bnode-coreference" sh "$root/scripts/run-w3c-bnode-coreference-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_ASK_SUITE="$w3c_root/sparql/sparql10/ask" sh "$root/scripts/run-w3c-ask-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_TYPE_PROMOTION_SUITE="$w3c_root/sparql/sparql10/type-promotion" sh "$root/scripts/run-w3c-m4-type-promotion-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_OPEN_WORLD_SUITE="$w3c_root/sparql/sparql10/open-world" sh "$root/scripts/run-w3c-m4-open-world-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_VALUES_SUITE="$w3c_root/sparql/sparql11/bindings" sh "$root/scripts/run-w3c-values-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M3_SUITE="$w3c_root/sparql" sh "$root/scripts/run-w3c-m3-pattern-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_ALGEBRA_SUITE="$w3c_root/sparql/sparql10/algebra" sh "$root/scripts/run-w3c-algebra-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_I18N_SUITE="$w3c_root/sparql/sparql10/i18n" sh "$root/scripts/run-w3c-i18n-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_EXPRESSION_SUITE="$w3c_root/sparql/sparql10/expr-equals" sh "$root/scripts/run-w3c-m4-expression-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_COMPARISON_SUITE="$w3c_root/sparql/sparql10/expr-ops" sh "$root/scripts/run-w3c-m4-comparison-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_BOOLEAN_SUITE="$w3c_root/sparql/sparql10/optional-filter" sh "$root/scripts/run-w3c-m4-boolean-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_BOUND_SUITE="$w3c_root/sparql/sparql10/bound" sh "$root/scripts/run-w3c-m4-bound-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_EBV_SUITE="$w3c_root/sparql/sparql10/boolean-effective-value" sh "$root/scripts/run-w3c-m4-ebv-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_UNARY_SUITE="$w3c_root/sparql/sparql10/expr-ops" sh "$root/scripts/run-w3c-m4-unary-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_ARITHMETIC_SUITE="$w3c_root/sparql/sparql10/expr-ops" sh "$root/scripts/run-w3c-m4-arithmetic-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_BUILTIN_SUITE="$w3c_root/sparql/sparql10/expr-builtin" sh "$root/scripts/run-w3c-m4-builtin-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_REGEX_SUITE="$w3c_root/sparql/sparql10/regex" sh "$root/scripts/run-w3c-m4-regex-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_MEMBERSHIP_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-membership-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_REPLACE_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-replace-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_NOW_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-now-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_UUID_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-uuid-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_RAND_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-rand-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_TEMPORAL_FUNCTION_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-temporal-function-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_CASE_SUITE="$w3c_root/sparql/sparql11/functions" sh "$root/scripts/run-w3c-m4-case-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_MODIFIER_SUITE="$w3c_root/sparql/sparql10/distinct" sh "$root/scripts/run-w3c-m4-modifier-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_REDUCED_SUITE="$w3c_root/sparql/sparql10/reduced" sh "$root/scripts/run-w3c-reduced-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_SOLUTION_SEQ_SUITE="$w3c_root/sparql/sparql10/solution-seq" sh "$root/scripts/run-w3c-solution-seq-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m4-ask-modifier-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_PROJECT_EXPRESSION_SUITE="$w3c_root/sparql/sparql11/project-expression" sh "$root/scripts/run-w3c-m4-project-expression-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_ORDER_SUITE="$w3c_root/sparql/sparql10/sort" sh "$root/scripts/run-w3c-m4-order-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_CAST_SUITE="$w3c_root/sparql/sparql10/cast" sh "$root/scripts/run-w3c-m4-cast-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_NEGATION_SUITE="$w3c_root/sparql/sparql11/negation" sh "$root/scripts/run-w3c-m4-exists-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M4_EXISTS_SUITE="$w3c_root/sparql/sparql11/exists" sh "$root/scripts/run-w3c-m4-exists-manifest-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M5_SUBQUERY_SUITE="$w3c_root/sparql/sparql11/subquery" sh "$root/scripts/run-w3c-m5-subquery-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m5-subquery-values-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m5-final-values-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M5_AGGREGATES_SUITE="$w3c_root/sparql/sparql11/aggregates" sh "$root/scripts/run-w3c-m5-aggregate-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m5-aggregate-expression-distinct-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M5_AGGREGATES_SUITE="$w3c_root/sparql/sparql11/aggregates" sh "$root/scripts/run-w3c-m5-aggregate-syntax-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M5_GROUPING_SUITE="$w3c_root/sparql/sparql11/grouping" sh "$root/scripts/run-w3c-m5-grouping-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M5_PROPERTY_PATH_SUITE="$w3c_root/sparql/sparql11/property-path" sh "$root/scripts/run-w3c-m5-property-path-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m5-bounded-path-extension-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_SPARQL10_CONSTRUCT_SUITE="$w3c_root/sparql/sparql10/construct" sh "$root/scripts/run-w3c-sparql10-construct-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M6_CONSTRUCT_SUITE="$w3c_root/sparql/sparql11/construct" sh "$root/scripts/run-w3c-m6-construct-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m6-construct-modifier-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m6-describe-policy-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M6_JSON_RESULT_SUITE="$w3c_root/sparql/sparql11/json-res" sh "$root/scripts/run-w3c-m6-json-result-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M6_CSV_TSV_RESULT_SUITE="$w3c_root/sparql/sparql11/csv-tsv-res" sh "$root/scripts/run-w3c-m6-csv-tsv-result-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m6-xml-result-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" sh "$root/scripts/run-m6-graph-result-tests.sh"
ODIN_RDF_COLLECTION="$odin_rdf" ODIN_GRAPH_COLLECTION="$odin_graph" W3C_M7_SERVICE_SUITE="$w3c_root/sparql/sparql11/service" sh "$root/scripts/run-w3c-m7-service-tests.sh"

printf '%s\n' 'offline development conformance verification completed'
