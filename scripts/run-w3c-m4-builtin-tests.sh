#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_M4_BUILTIN_SUITE:-}" ]; then
  suite=$W3C_M4_BUILTIN_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/expr-builtin"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

total=0
failed=0
for name in sameTerm sameTerm-eq sameTerm-not-eq str-1 str-2 str-3 str-4 lang-1 lang-2 lang-3 datatype-1 datatype-2 datatype-3 blank-1 iri-1 uri-1 langMatches-1 langMatches-2 langMatches-3 langMatches-4 langMatches-de-de lang-case-insensitive-eq lang-case-insensitive-ne case-insensitive-booleans
do
  total=$((total + 1))
  query="$suite/$name.rq"
  data="$suite/data-builtin-1.ttl"
  result="$suite/result-$name.ttl"
  case "$name" in
    str-*|blank-*|iri-*|uri-*|langMatches-*) query="$suite/q-$name.rq" ;;
	lang-*) query="$suite/q-$name.rq"; data="$suite/data-builtin-2.ttl"; result="$suite/result-$name.srx" ;;
	datatype-*) query="$suite/q-$name.rq"; data="$suite/data-builtin-2.ttl"; result="$suite/result-$name.srx" ;;
  esac
  case "$name" in
    str-*) result="$suite/result-$name.ttl" ;;
    datatype-1) data="$suite/data-builtin-1.ttl"; result="$suite/result-$name.ttl" ;;
    langMatches-de-de) data="$suite/data-langMatches-de.ttl"; result="$suite/result-langMatches-de.ttl" ;;
	langMatches-*) data="$suite/data-langMatches.ttl" ;;
	lang-case-insensitive-eq) query="$suite/lang-case-sensitivity-eq.rq"; data="$suite/lang-case-sensitivity.ttl"; result="$suite/lang-case-insensitive-eq.srx" ;;
	lang-case-insensitive-ne) query="$suite/lang-case-sensitivity-ne.rq"; data="$suite/lang-case-sensitivity.ttl"; result="$suite/lang-case-insensitive-ne.srx" ;;
	case-insensitive-booleans) data=/dev/null; result="$suite/case-insensitive-booleans.srx" ;;
  esac
  if [ "$name" = langMatches-1 ] || [ "$name" = langMatches-2 ] || [ "$name" = langMatches-3 ] || [ "$name" = langMatches-4 ]; then
    if ! "$runner" --base "https://example.invalid/odin-sparql/w3c/" "$query" "$data" "$result"; then
      failed=$((failed + 1))
    fi
  elif ! "$runner" "$query" "$data" "$result"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 builtin subset: total=$total failed=$failed"
[ "$total" -eq 24 ]
[ "$failed" -eq 0 ]
