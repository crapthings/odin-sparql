#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M6_CONSTRUCT_SUITE:-}" ]; then
  suite=$W3C_M6_CONSTRUCT_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/construct"
fi
runner="$root/.cache/odin-sparql-basic-runner"
syntax_runner="$root/.cache/odin-sparql-syntax-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
odin build "$root/tests/w3c/syntax_runner" -out:"$syntax_runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

evaluation_total=0
evaluation_failed=0
run_case() {
  evaluation_total=$((evaluation_total + 1))
  if ! "$runner" "$suite/$1.rq" "$suite/data.ttl" "$suite/${1}result.ttl"; then
    evaluation_failed=$((evaluation_failed + 1))
  fi
}

run_case constructwhere01
run_case constructwhere02
run_case constructwhere03
run_case constructlist

# constructwhere04 declares FROM <data.ttl>. Its query base and the
# application-owned named graph use the same file URI, so this remains an
# offline test of relative-IRI dataset-description resolution.
suite_abs=$(cd "$suite" && pwd)
suite_base="file://$suite_abs/"
evaluation_total=$((evaluation_total + 1))
if ! "$runner" --named "$suite_abs/constructwhere04.rq" "$suite_abs/constructwhere04result.ttl" "$suite_base" "${suite_base}data.ttl" "$suite_abs/data.ttl"; then
  evaluation_failed=$((evaluation_failed + 1))
fi

syntax_total=0
syntax_failed=0
run_negative_syntax() {
  syntax_total=$((syntax_total + 1))
  if ! "$syntax_runner" negative "$suite/$1.rq"; then
    syntax_failed=$((syntax_failed + 1))
  fi
}

# CONSTRUCT WHERE is the shortcut form and only permits a BGP. FILTER and
# GRAPH therefore make these manifest entries negative syntax tests.
run_negative_syntax constructwhere05
run_negative_syntax constructwhere06

printf '%s\n' "W3C SPARQL M6 CONSTRUCT: evaluation_total=$evaluation_total evaluation_failed=$evaluation_failed syntax_total=$syntax_total syntax_failed=$syntax_failed"
[ "$evaluation_total" -eq 5 ]
[ "$evaluation_failed" -eq 0 ]
[ "$syntax_total" -eq 2 ]
[ "$syntax_failed" -eq 0 ]
