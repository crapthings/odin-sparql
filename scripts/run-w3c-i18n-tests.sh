#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_I18N_SUITE:-}" ]; then
  suite=$W3C_I18N_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/i18n"
fi
runner="$root/.cache/odin-sparql-basic-runner"
base="http://www.w3.org/2001/sw/DataAccess/tests/data/i18n/"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
run_case() {
  total=$((total + 1))
  if ! "$runner" --base "$base" "$suite/$1.rq" "$suite/$2.ttl" "$suite/$1-results.ttl"; then
    failed=$((failed + 1))
  fi
}

run_case kanji-01 kanji
run_case kanji-02 kanji
run_case normalization-01 normalization-01
run_case normalization-02 normalization-02
run_case normalization-03 normalization-03

printf '%s\n' "W3C SPARQL i18n: total=$total failed=$failed"
[ "$total" -eq 5 ]
[ "$failed" -eq 0 ]
