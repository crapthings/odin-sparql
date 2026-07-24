#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_BASIC_SUITE:-}" ]; then
  suite=$W3C_BASIC_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/basic"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in base-prefix-1 base-prefix-2 base-prefix-3 base-prefix-4 base-prefix-5 list-1 list-2 list-3 list-4 quotes-1 quotes-2 quotes-3 quotes-4 term-1 term-2 term-3 term-4 term-5 term-6 term-7 term-8 term-9 var-1 var-2 bgp-no-match spoo-1 prefix-name-1
do
  case "$name" in
    base-prefix-*) data=data-1.ttl ;;
    list-*) data=data-2.ttl ;;
    quotes-*) data=data-3.ttl ;;
    term-*) data=data-4.ttl ;;
    var-*) data=data-5.ttl ;;
    bgp-no-match) data=data-7.ttl ;;
    spoo-1|prefix-name-1) data=data-6.ttl ;;
  esac
  total=$((total + 1))
  if ! "$runner" "$suite/$name.rq" "$suite/$data" "$suite/$name.srx"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL Basic BGP subset: total=$total failed=$failed"
[ "$total" -eq 27 ]
[ "$failed" -eq 0 ]
