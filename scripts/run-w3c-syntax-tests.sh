#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
if [ -n "${W3C_SYNTAX_SUITE:-}" ]; then
  suite=$W3C_SYNTAX_SUITE
else
  suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
fi
runner="$root/.cache/odin-sparql-syntax-runner"

odin build "$root/tests/w3c/syntax_runner" \
  -out:"$runner" \
  -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"

entries=$(awk '
  /rdf:type[[:space:]]+mf:PositiveSyntaxTest11/ { kind = "positive" }
  /rdf:type[[:space:]]+mf:NegativeSyntaxTest11/ { kind = "negative" }
  /mf:action[[:space:]]+</ {
    file = $0
    sub(/^.*</, "", file)
    sub(/>.*$/, "", file)
    print kind "|" file
  }
' "$suite/manifest.ttl")

total=0
positives=0
negatives=0
failed=0
while IFS='|' read -r kind file; do
  [ -n "$kind" ] || continue
  total=$((total + 1))
  if [ "$kind" = positive ]; then
    positives=$((positives + 1))
  else
    negatives=$((negatives + 1))
  fi
  if ! "$runner" "$kind" "$suite/$file"; then
    failed=$((failed + 1))
  fi
done <<EOF
$entries
EOF

if [ "$total" -ne 94 ] || [ "$positives" -ne 63 ] || [ "$negatives" -ne 31 ]; then
  printf '%s\n' "unexpected pinned syntax manifest shape: total=$total positive=$positives negative=$negatives" >&2
  exit 1
fi

printf '%s\n' "W3C SPARQL 1.1 syntax: total=$total positive=$positives negative=$negatives failed=$failed"
[ "$failed" -eq 0 ]
