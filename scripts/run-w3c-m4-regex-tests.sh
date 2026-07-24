#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_REGEX_SUITE:-}" ]; then
  suite=$W3C_M4_REGEX_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/regex"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in \
  regex-quantifier-optional \
  regex-quantifier-zero-or-more \
  regex-quantifier-one-or-more \
  regex-quantifier-counted-exact \
  regex-quantifier-counted-lower-bound \
  regex-quantifier-counted-lower-upper-bounds \
  regex-dot \
  regex-dot-all \
  regex-case-insensitive \
  regex-no-metacharacters \
  regex-no-metacharacters-case-insensitive \
  regex-start-end \
  regex-start-end-multiline \
  regex-char-class-expression \
  regex-negative-char-class-expression \
  regex-ignore-whitespaces \
  regex-ignore-whitespaces-class-expression
do
  total=$((total + 1))
  result="$suite/$name.srx"
  if [ "$name" = regex-no-metacharacters-case-insensitive ]; then
    result="$suite/regex-no-metacharacters.srx"
  fi
  if ! "$runner" "$suite/$name.rq" "$suite/regex-data-quantifiers.ttl" "$result"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 regex subset: total=$total failed=$failed"
[ "$total" -eq 17 ]
[ "$failed" -eq 0 ]
