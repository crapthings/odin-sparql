#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
if [ -n "${W3C_M4_MEMBERSHIP_SUITE:-}" ]; then
  suite=$W3C_M4_MEMBERSHIP_SUITE
else
  syntax_suite=$(sh "$root/scripts/fetch-w3c-tests.sh")
  fixture_root=${syntax_suite%/sparql/sparql11/syntax-query}
  suite="$fixture_root/sparql/sparql11/functions"
fi
runner="$root/.cache/odin-sparql-basic-runner"
fixture_root=${suite%/sparql/sparql11/functions}
data="$fixture_root/sparql/sparql10/expr-builtin/data-builtin-1.ttl"

odin build "$root/tests/w3c/basic_runner" -out:"$runner" -collection:odin-rdf="$odin_rdf"

total=0
failed=0
for name in in01 in02 notin01 notin02 isnumeric01 if01 if02 coalesce-empty coalesce01 abs01 ceil01 floor01 round01 concat01 concat02 concat-empty concat-single starts01 ends01 contains01 plus-1-corrected plus-2-corrected length01 length01-non-bmp encode01 encode01-non-bmp substring01 substring02 substring01-non-bmp substring02-non-bmp md5-01 md5-02 sha1-01 sha1-02 sha256-01 sha256-02 sha384-01 sha384-02 sha512-01 sha512-02 strbefore01a strafter01a strbefore02 strafter02 strdt01 strdt02 strdt03-rdf11 strlang01 strlang02 strlang03-rdf11 bnode01 bnode02 iri01 iri02
do
  total=$((total + 1))
  query="$suite/$name.rq"
  result="$suite/$name.srx"
  case "$name" in
    isnumeric01) case_data="$suite/data.ttl" ;;
	if01) case_data="$suite/data2.ttl" ;;
	if02) case_data="$suite/data-empty.nt" ;;
	coalesce01|coalesce-empty) case_data="$suite/data-coalesce.ttl" ;;
	notin02) case_data="$suite/data.ttl" ;;
	abs01|ceil01|floor01|round01) case_data="$suite/data.ttl" ;;
    concat01|concat-empty|concat-single) case_data="$suite/data.ttl" ;;
    concat02) case_data="$suite/data2.ttl" ;;
    starts01|ends01|contains01) case_data="$suite/data.ttl" ;;
	plus-1-corrected) case_data="$suite/data-builtin-3.ttl"; result="$suite/plus-1.srx" ;;
	plus-2-corrected) case_data="$suite/data-builtin-3.ttl"; result="$suite/plus-2.srx" ;;
    length01) case_data="$suite/data.ttl" ;;
    length01-non-bmp) query="$suite/length01.rq"; case_data="$suite/data5.ttl"; result="$suite/length01-non-bmp.srx" ;;
    encode01) case_data="$suite/data.ttl" ;;
    encode01-non-bmp) query="$suite/encode01.rq"; case_data="$suite/data5.ttl"; result="$suite/encode01-non-bmp.srx" ;;
    substring01|substring02) case_data="$suite/data.ttl" ;;
    substring01-non-bmp) query="$suite/substring01.rq"; case_data="$suite/data5.ttl"; result="$suite/substring01-non-bmp.srx" ;;
    substring02-non-bmp) query="$suite/substring02.rq"; case_data="$suite/data5.ttl"; result="$suite/substring02-non-bmp.srx" ;;
    md5-01|md5-02|sha1-01|sha256-01|sha384-01|sha512-01) case_data="$suite/data.ttl" ;;
    sha1-02|sha256-02|sha384-02|sha512-02) case_data="$suite/hash-unicode.ttl" ;;
    strbefore01a) query="$suite/strbefore01.rq"; case_data="$suite/data2.ttl"; result="$suite/strbefore01a.srx" ;;
    strafter01a) query="$suite/strafter01.rq"; case_data="$suite/data2.ttl"; result="$suite/strafter01a.srx" ;;
    strbefore02|strafter02) case_data="$suite/data4.ttl" ;;
    strdt01|strdt02) case_data="$suite/data.ttl" ;;
    strdt03-rdf11) query="$suite/strdt03.rq"; case_data="$suite/data.ttl"; result="$suite/strdt03-rdf11.srx" ;;
	strlang01|strlang02) case_data="$suite/data.ttl" ;;
	strlang03-rdf11) query="$suite/strlang03.rq"; case_data="$suite/data.ttl"; result="$suite/strlang03-rdf11.srx" ;;
	bnode01|bnode02) case_data="$suite/data.ttl" ;;
	iri01|iri02) case_data="$suite/data-empty.nt" ;;
    *) case_data="$data" ;;
  esac
  if ! "$runner" "$query" "$case_data" "$result"; then
    failed=$((failed + 1))
  fi
done

printf '%s\n' "W3C SPARQL M4 core function subset: total=$total failed=$failed"
[ "$total" -eq 54 ]
[ "$failed" -eq 0 ]
