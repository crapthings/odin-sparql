#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ci="$root/.github/workflows/ci.yml"
guide="$root/docs/releasing.md"
verify="$root/scripts/verify-release.sh"
rdf_revision='a4024ddec94fbdcd810631206752d87c5595120f'
w3c_revision='d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86'

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

grep -Fq -- "$rdf_revision" "$ci" || fail "CI odin-rdf revision is missing"
grep -Fq -- "development convergence baseline" "$ci" || fail "CI odin-rdf development marker is missing"
grep -Fq -- "$rdf_revision" "$guide" || fail "release guide odin-rdf revision is missing"
grep -Fq -- "development convergence baseline" "$guide" || fail "release guide odin-rdf development marker is missing"
grep -Fq -- "$w3c_revision" "$guide" || fail "release guide W3C revision is missing"
grep -Fq -- "$w3c_revision" "$verify" || fail "offline verifier W3C revision is missing"
grep -Fq -- 'sh "$root/scripts/check-release-facts.sh"' "$verify" || fail "offline verifier does not check release facts"
grep -Fq -- 'odin run "$root/examples/minimal"' "$verify" || fail "offline verifier does not run the public example"
grep -Fq -- 'odin run "$root/examples/custom_view"' "$verify" || fail "offline verifier does not run the public custom View example"
grep -Fq -- 'odin check "$root/sparql/dataset"' "$verify" || fail "offline verifier does not strictly check the Dataset API"
