#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_TEMPORAL_FUNCTION_SUITE:-}" ]; then
	suite=$W3C_M4_TEMPORAL_FUNCTION_SUITE
else
	syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
	fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
	suite="$fixture_root/sparql/sparql11/functions"
fi
runner="$root/.cache/odin-sparql-basic-runner"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=8
failed=0
for name in hours-01 minutes-01 seconds-01 year-01 month-01 day-01 timezone-01 tz-01; do
	if ! "$runner" "$suite/$name.rq" "$suite/data.ttl" "$suite/$name.srx"; then
		failed=$((failed + 1))
	fi
done

printf '%s\n' "W3C SPARQL M4 temporal functions: total=$total failed=$failed"
[ "$failed" -eq 0 ]
