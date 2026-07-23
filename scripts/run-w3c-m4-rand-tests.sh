#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_RAND_SUITE:-}" ]; then
	suite=$W3C_M4_RAND_SUITE
else
	syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
	fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
	suite="$fixture_root/sparql/sparql11/functions"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=1
failed=0
if ! "$runner" "$suite/rand01.rq" "$suite/data.ttl" "$suite/rand01.srx"; then
	failed=1
fi

printf '%s\n' "W3C SPARQL M4 RAND subset: total=$total failed=$failed"
[ "$failed" -eq 0 ]
