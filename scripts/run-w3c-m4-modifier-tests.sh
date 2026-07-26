#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_MODIFIER_SUITE:-}" ]; then
  suite=$W3C_M4_MODIFIER_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql10/distinct"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in num str node opt all star
do
  total=$((total + 1))
  case "$name" in
    num) query="$suite/distinct-1.rq"; data="$suite/data-num.ttl"; result="$suite/distinct-num.srx" ;;
    str) query="$suite/distinct-1.rq"; data="$suite/data-str.ttl"; result="$suite/distinct-str.srx" ;;
    node) query="$suite/distinct-1.rq"; data="$suite/data-node.ttl"; result="$suite/distinct-node.srx" ;;
    opt) query="$suite/distinct-2.rq"; data="$suite/data-opt.ttl"; result="$suite/distinct-opt.srx" ;;
    all) query="$suite/distinct-1.rq"; data="$suite/data-all.ttl"; result="$suite/distinct-all.srx" ;;
    star) query="$suite/distinct-star-1.rq"; data="$suite/data-star.ttl"; result="$suite/distinct-star-1.srx" ;;
  esac
  if ! "$runner" "$query" "$data" "$result"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 DISTINCT subset: total=$total failed=$failed"
[ "$total" -eq 6 ]
[ "$failed" -eq 0 ]
