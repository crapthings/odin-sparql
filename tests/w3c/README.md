# W3C SPARQL 1.1 Query syntax fixture

The conformance gate uses the official
[`w3c/rdf-tests`](https://github.com/w3c/rdf-tests) revision
`d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86`, specifically
`sparql/sparql11/syntax-query/manifest.ttl`.

`scripts/fetch-w3c-tests.sh` fetches that exact source archive into the ignored
`.cache/` directory and prints the fixture directory. A test run must consume
the cached fixture after this step; production packages never download it.

The manifest has both `mf:PositiveSyntaxTest11` and
`mf:NegativeSyntaxTest11` entries. Run the complete pinned syntax gate with:

```sh
sh scripts/run-w3c-syntax-tests.sh
```

It builds the syntax runner into `.cache/`, then checks all 63 positive and 31
negative entries. Set `ODIN_RDF_COLLECTION` when `odin-rdf` is not located at
the sibling path `../odin-rdf`. For offline verification, set
`W3C_SYNTAX_SUITE` to an already-cached `syntax-query` fixture directory.

## Basic graph-pattern evaluation

`scripts/run-w3c-basic-tests.sh` evaluates the supported BGP subset of the
SPARQL 1.0 Basic manifest through Turtle loading, the in-memory Dataset, and
SRX result-multiset comparison:

```sh
sh scripts/run-w3c-basic-tests.sh
```

It covers all 27 entries: BASE/PREFIX, RDF collection lowering (empty,
single-item, variable-item, and two-item lists), quoted and typed literals,
RDF terms, variable identity, no-match, object-list shorthand, and
empty-prefix names. Set `W3C_BASIC_SUITE` to an already-cached
`sparql/sparql10/basic` directory for offline verification.

## Internationalized query evaluation

`scripts/run-w3c-i18n-tests.sh` runs all five entries from the SPARQL 1.0
`i18n` manifest. It covers Unicode prefixed names, wide whitespace, and
normalized/non-normalized Unicode IRI spellings. Fixture data is parsed with
the manifest's official I18N document base for its relative IRIs.

```sh
sh scripts/run-w3c-i18n-tests.sh
```

For offline verification, set `W3C_I18N_SUITE` to the cached
`sparql/sparql10/i18n` directory.

## Triple-pattern matching

`scripts/run-w3c-triple-match-tests.sh` runs the complete four-entry SPARQL
1.0 `triple-match` manifest. It covers fixed terms, repeated variables within
one triple, and two triple patterns joined by a shared variable. The final
fixture is loaded with its published document base because its Turtle data
contains a relative IRI.

```sh
sh scripts/run-w3c-triple-match-tests.sh
```

For offline verification, set `W3C_TRIPLE_MATCH_SUITE` to the cached
`sparql/sparql10/triple-match` directory.

## Blank-node coreference

`scripts/run-w3c-bnode-coreference-tests.sh` runs the complete one-entry
SPARQL 1.0 `bnode-coreference` manifest. Its result comparison uses a
one-to-one mapping for document-local blank-node labels.

```sh
sh scripts/run-w3c-bnode-coreference-tests.sh
```

For offline verification, set `W3C_BNODE_COREFERENCE_SUITE` to the cached
`sparql/sparql10/bnode-coreference` directory.

## ASK evaluation

`scripts/run-w3c-ask-tests.sh` runs all four entries from the pinned SPARQL 1.0
`ask` manifest. They cover true/false results, variables, and FILTER using
SPARQL XML boolean-result comparison.

```sh
sh scripts/run-w3c-ask-tests.sh
```

For offline verification, set `W3C_ASK_SUITE` to an already-cached
`sparql/sparql10/ask` directory.

## Solution sequence

`scripts/run-w3c-solution-seq-tests.sh` runs all thirteen entries from the
SPARQL 1.0 `solution-seq` manifest: four `LIMIT`, four `OFFSET`, and five
combined slice cases over `ORDER BY` results.

```sh
sh scripts/run-w3c-solution-seq-tests.sh
```

For offline verification, set `W3C_SOLUTION_SEQ_SUITE` to the cached
`sparql/sparql10/solution-seq` directory.

## REDUCED evaluation

`scripts/run-w3c-reduced-tests.sh` runs both entries from the SPARQL 1.0
`reduced` manifest. Its `mf:LaxCardinality` comparator accepts only a bounded
sub-multiset of the expected rows that still represents every distinct mapping;
it does not treat `REDUCED` as arbitrary result loss.

```sh
sh scripts/run-w3c-reduced-tests.sh
```

For offline verification, set `W3C_REDUCED_SUITE` to the cached
`sparql/sparql10/reduced` directory.

## VALUES evaluation

`scripts/run-w3c-values-tests.sh` runs the eight `values01` through `values08`
entries from the pinned SPARQL 1.1 `bindings` manifest. They exercise inline
and trailing `VALUES`, multi-column rows, `UNDEF`, joins, and `OPTIONAL`.

```sh
sh scripts/run-w3c-values-tests.sh
```

For offline verification, set `W3C_VALUES_SUITE` to an already-cached
`sparql/sparql11/bindings` directory.

## M3 graph-pattern evaluation

`scripts/run-w3c-m3-pattern-tests.sh` runs fifty-one pinned evaluation
entries: seven SPARQL 1.0 OPTIONAL/UNION cases (including nested complex
OPTIONAL), all seventeen SPARQL 1.0 GRAPH cases, three SPARQL 1.0 FILTER equality cases,
two SPARQL 1.1 MINUS cases, and ten SPARQL 1.1 BIND/scope cases, plus
the complete twelve-entry SPARQL 1.0 Dataset manifest. It uses the same multiset
comparator, with both SRX and standard RDF/Turtle result-set serializations.

```sh
sh scripts/run-w3c-m3-pattern-tests.sh
```

For offline verification, set `W3C_M3_SUITE` to the cached `sparql` directory
that contains the `sparql10` and `sparql11` subdirectories.

## Algebra evaluation

`scripts/run-w3c-algebra-tests.sh` runs the complete fourteen-entry SPARQL 1.0
`algebra` manifest. It covers nested OPTIONAL, FILTER placement and scope,
variable scope through joins, and composed JOIN/OPTIONAL/UNION/GRAPH patterns.
The runner loads fixture data with its official document base and constructs
the manifest's one named graph explicitly.

```sh
sh scripts/run-w3c-algebra-tests.sh
```

For offline verification, set `W3C_ALGEBRA_SUITE` to the cached
`sparql/sparql10/algebra` directory.

## M4 value equality and numeric comparison

`scripts/run-w3c-m4-expression-tests.sh` runs the complete fifteen-entry
SPARQL 1.0 `expr-equals` manifest. It exercises numeric promotion,
string/IRI, boolean, float, and `xsd:dateTime` value equality in `FILTER`
expressions, two-variable equality, and graph-term equality. The dateTime
entry includes timezone-normalized instants, `24:00:00` next-day normalization,
and fractional-second trailing zeroes.

```sh
sh scripts/run-w3c-m4-expression-tests.sh
```

For offline verification, set `W3C_M4_EXPRESSION_SUITE` to the cached
`sparql/sparql10/expr-equals` directory.

`scripts/run-w3c-m4-comparison-tests.sh` runs the numeric `ge-1` and `le-1`
entries plus all four `xsd:dateTime` relation entries from the SPARQL 1.0
`expr-ops` manifest. The latter cover `<`, `<=`, `>`, and `>=` across
timezone-qualified, timezone-absent, and mixed inputs. Date/time casts and
temporal ordering remain deferred.

```sh
sh scripts/run-w3c-m4-comparison-tests.sh
```

For offline verification, set `W3C_M4_COMPARISON_SUITE` to the cached
`sparql/sparql10/expr-ops` directory.

`scripts/run-w3c-m4-type-promotion-tests.sh` runs all thirty entries from the
pinned SPARQL 1.0 `type-promotion` manifest. It verifies XML Schema integer
derivations, promotion to integer/decimal/float/double, and non-promoting
comparison failures.

```sh
sh scripts/run-w3c-m4-type-promotion-tests.sh
```

For offline verification, set `W3C_M4_TYPE_PROMOTION_SUITE` to the cached
`sparql/sparql10/type-promotion` directory.

`scripts/run-w3c-m4-open-world-tests.sh` runs eighteen direct-comparison
entries from the pinned SPARQL 1.0 `open-world` manifest. It covers supported
numeric equality, language-string identity, invalid and unknown datatype
boundaries, and relational comparison without making a closed-world claim
about unknown datatype value spaces. It also covers `open-eq-12`'s
OPTIONAL-local `!= || =` error propagation over correlated left-side bindings,
plus all four `xsd:date` entries. The date slice validates calendar and
timezone lexical forms, retains timezone absence during equality, and supports
date relations. `xsd:dateTime` equality and temporal casts remain deferred.

```sh
sh scripts/run-w3c-m4-open-world-tests.sh
```

For offline verification, set `W3C_M4_OPEN_WORLD_SUITE` to the cached
`sparql/sparql10/open-world` directory.

`scripts/run-w3c-m4-boolean-tests.sh` runs `expr-3` and `expr-4` from the
SPARQL 1.0 `optional-filter` manifest. It verifies `&&` in an OPTIONAL-scoped
FILTER and `BOUND` plus `||` for an unbound OPTIONAL variable.

```sh
sh scripts/run-w3c-m4-boolean-tests.sh
```

For offline verification, set `W3C_M4_BOOLEAN_SUITE` to the cached
`sparql/sparql10/optional-filter` directory.

`scripts/run-w3c-m4-bound-tests.sh` runs the complete one-entry SPARQL 1.0
`bound` manifest, independently verifying direct `BOUND` filtering.

```sh
sh scripts/run-w3c-m4-bound-tests.sh
```

For offline verification, set `W3C_M4_BOUND_SUITE` to the cached
`sparql/sparql10/bound` directory.

`scripts/run-w3c-m4-ebv-tests.sh` runs all seven entries from the pinned
SPARQL 1.0 `boolean-effective-value` manifest. It covers boolean, numeric,
and string effective boolean values plus logical and error behavior.

```sh
sh scripts/run-w3c-m4-ebv-tests.sh
```

For offline verification, set `W3C_M4_EBV_SUITE` to the cached
`sparql/sparql10/boolean-effective-value` directory.

`scripts/run-w3c-m4-unary-tests.sh` runs all four unary numeric entries
(`unplus-1`, `unminus-1`, `unplus-2`, and `unminus-2`) from the SPARQL 1.0
`expr-ops` manifest.

```sh
sh scripts/run-w3c-m4-unary-tests.sh
```

For offline verification, set `W3C_M4_UNARY_SUITE` to the cached
`sparql/sparql10/expr-ops` directory.

`scripts/run-w3c-m4-arithmetic-tests.sh` runs `plus-1`, `minus-1`, `mul-1`,
`add-literals`, and the four mixed-type `*-numbers-cast` entries from the
SPARQL 1.0 `expr-ops` manifest. The latter cover all
integer/decimal/float/double type-promotion combinations for `+`, `-`, `*`,
and `/`; the runner supplies an explicit numeric-digit limit.

```sh
sh scripts/run-w3c-m4-arithmetic-tests.sh
```

For offline verification, set `W3C_M4_ARITHMETIC_SUITE` to the cached
`sparql/sparql10/expr-ops` directory.

`scripts/run-w3c-m4-regex-tests.sh` runs twenty-one entries from the pinned
SPARQL 1.0 `regex` manifest. It covers quantifiers, character classes,
anchors, and the `i`, `m`, `s`, `x`, and `q` flags, including four historic
Turtle result-set entries with trailing-semicolon blank-property lists.

```sh
sh scripts/run-w3c-m4-regex-tests.sh
```

For offline verification, set `W3C_M4_REGEX_SUITE` to the cached
`sparql/sparql10/regex` directory.

`scripts/run-w3c-m4-builtin-tests.sh` runs twenty-five `sameTerm`, `STR`,
`LANG`, `DATATYPE`, `isBlank`, `isLiteral`, `isIRI`, `isURI`, and `langMatches` entries
from the SPARQL 1.0 `expr-builtin` manifest, including case-insensitive
language tags and boolean keywords. The shared result comparator handles
document-local blank-node identifiers through a one-to-one mapping.
`isLiteral` is also executed through its official Turtle result fixture,
including its trailing semicolon in a nested property list.

```sh
sh scripts/run-w3c-m4-builtin-tests.sh
```

For offline verification, set `W3C_M4_BUILTIN_SUITE` to the cached
`sparql/sparql10/expr-builtin` directory.

## M4 core functions

`scripts/run-w3c-m4-membership-tests.sh` runs `in01`, `in02`, `notin01`,
`notin02`,
`isnumeric01`, `if01`, `if02`, and the empty-argument error case for
`COALESCE`, plus
the `ABS`, `CEIL`, `FLOOR`, and `ROUND` exact-numeric cases, plus four
`CONCAT` cases from the SPARQL 1.1 `functions` manifest. It also covers
`STRSTARTS`, `STRENDS`, and `CONTAINS`, plus `plus-2-corrected` (a string `+`
type error). The shared runner compares SRX ASK
results, in addition to SELECT result multisets. It also runs the BMP and
non-BMP `STRLEN` fixtures plus language-tag-preserving and incompatible-tag
error `STRBEFORE`/`STRAFTER` cases, BMP and non-BMP `ENCODE_FOR_URI` and `SUBSTR` fixtures, and three
`STRDT` cases plus all three `STRLANG` cases. It also covers both `BNODE`
fixtures, including solution-local string identity and no-argument freshness.
It includes the ten official `MD5`, `SHA1`, `SHA256`,
`SHA384`, and `SHA512` vectors, including Unicode input cases, plus `IRI` and
`URI` BASE-resolution fixtures. The current total is 54 cases, including
`coalesce01`, canonical integral `xsd:decimal` results, and the
blank-node-containing `plus-1-corrected` vector; the result comparator maps
document-local blank nodes one-to-one.

```sh
sh scripts/run-w3c-m4-membership-tests.sh
```

For offline verification, set `W3C_M4_MEMBERSHIP_SUITE` to the cached
`sparql/sparql11/functions` directory.

`scripts/run-w3c-m4-case-tests.sh` runs `LCASE` and `UCASE` on the approved
baseline data plus the proposed non-BMP vectors. It verifies language-tag
preservation and Unicode code-point mapping.

```sh
sh scripts/run-w3c-m4-case-tests.sh
```

For offline verification, set `W3C_M4_CASE_SUITE` to the cached
`sparql/sparql11/functions` directory.

`scripts/run-w3c-m4-now-tests.sh` runs the approved `now01` function vector.
The W3C basic runner injects a fixed query clock so that this dynamic-value
fixture is reproducible.

`scripts/run-w3c-m4-uuid-tests.sh` runs `uuid01`, `struuid01`, and `uuid02`.
They verify the UUID IRI form, the plain-string form, and per-invocation
freshness. Production execution uses a cryptographically secure UUID v4
source; tests may inject an explicit source through `engine.Options`.

`scripts/run-w3c-m4-rand-tests.sh` runs the approved `rand01` vector. It
verifies that `RAND()` returns an `xsd:double` in `[0,1)`. The default samples
cryptographic entropy; deterministic execution uses `engine.Options.RAND_Callback`.

`scripts/run-w3c-m4-temporal-function-tests.sh` runs eight approved vectors:
`YEAR`, `MONTH`, `DAY`, `HOURS`, `MINUTES`, `SECONDS`, `TIMEZONE`, and `TZ`.
They cover dateTime components, seconds as decimals, present and absent
timezones, and duration/string timezone result forms.

`scripts/run-w3c-m4-replace-tests.sh` runs `replace01` through `replace03`
plus the case-insensitive vector. It covers global non-overlapping replacement,
language-tag preservation, alternatives with an unmatched capture group,
`$n` substitution, and the `i` flag. The first three vectors use `data3.ttl`;
the last is a dataset-free query.

For offline verification, set `W3C_M4_NOW_SUITE`, `W3C_M4_UUID_SUITE`,
`W3C_M4_RAND_SUITE`, `W3C_M4_TEMPORAL_FUNCTION_SUITE`, or
`W3C_M4_REPLACE_SUITE` to the cached `sparql/sparql11/functions` directory.

## M4 solution modifiers

`scripts/run-w3c-m4-modifier-tests.sh` runs six pinned SPARQL 1.0 `DISTINCT`
entries: numeric, string, blank-node, OPTIONAL, mixed-data, and `SELECT *`
projections. `REDUCED` has focused engine coverage; its W3C manifest declares
lax cardinality, which the current exact-multiset runner intentionally does
not treat as an ordinary equality gate.

```sh
sh scripts/run-w3c-m4-modifier-tests.sh
```

For offline verification, set `W3C_M4_MODIFIER_SUITE` to the cached
`sparql/sparql10/distinct` directory.

## M4 ASK solution modifiers

`scripts/run-m4-ask-modifier-tests.sh` runs five local ASK fixtures through
the external runner. They prove ordered OFFSET/LIMIT, GROUP BY/HAVING, and
LIMIT 0 affect the final boolean. This is a release-gated semantic check, not
a W3C manifest claim.

```sh
sh scripts/run-m4-ask-modifier-tests.sh
```

## M4 projection expressions

`scripts/run-w3c-m4-project-expression-tests.sh` runs all seven entries from
the pinned SPARQL 1.1 `project-expression` manifest. It covers alias reuse,
`ORDER BY` over an alias, and unbound results from projection-expression
errors.

```sh
sh scripts/run-w3c-m4-project-expression-tests.sh
```

For offline verification, set `W3C_M4_PROJECT_EXPRESSION_SUITE` to the cached
`sparql/sparql11/project-expression` directory.

## M4 ordering

`scripts/run-w3c-m4-order-tests.sh` runs fourteen applicable SPARQL 1.0
`sort` entries with ordered result comparison. The runner accepts legacy
RDF/XML result sets and uses `rs:index` when Turtle result sets encode an
explicit sequence. The historical `sort-11` plain-literal versus `xsd:string`
distinction is excluded under the RDF 1.1 `odin-rdf` term model.

```sh
sh scripts/run-w3c-m4-order-tests.sh
```

For offline verification, set `W3C_M4_ORDER_SUITE` to the cached
`sparql/sparql10/sort` directory.

## M4 scalar casts

`scripts/run-w3c-m4-cast-tests.sh` runs seven conversion entries from the SPARQL
1.0 `cast` manifest: `xsd:integer`, `xsd:decimal`, `xsd:boolean`,
`xsd:string`, `xsd:float`, `xsd:double`, and `xsd:dateTime`. The dateTime
cast validates accepted string lexical forms while preserving their spelling.

```sh
sh scripts/run-w3c-m4-cast-tests.sh
```

For offline verification, set `W3C_M4_CAST_SUITE` to the cached
`sparql/sparql10/cast` directory.

## M4 correlated EXISTS

`scripts/run-w3c-m4-exists-tests.sh` runs all ten SPARQL 1.1 `negation`
manifest fixtures:
positive EXISTS, correlated NOT EXISTS, MINUS set exclusion, temporal
exclusion, nested MINUS, lexical string comparison, and named-graph MINUS
disjointness.

`scripts/run-w3c-m4-exists-manifest-tests.sh` separately runs the complete
six-entry SPARQL 1.1 `exists` manifest, including nested EXISTS/NOT EXISTS,
active named-graph scope, and a graph variable correlated from the outer
solution.

```sh
sh scripts/run-w3c-m4-exists-tests.sh
sh scripts/run-w3c-m4-exists-manifest-tests.sh
```

For offline verification, set `W3C_M4_NEGATION_SUITE` to the cached
`sparql/sparql11/negation` directory, or `W3C_M4_EXISTS_SUITE` to the cached
`sparql/sparql11/exists` directory.

## M5 subqueries

`scripts/run-w3c-m5-subquery-tests.sh` runs seven pinned SPARQL 1.1 `subquery`
fixtures: `sq08` through `sq14`, excluding the RDF/XML-reader-blocked first
seven entries. They verify aggregates, nested `SELECT *` boundaries, correlated
EXISTS, subquery-local LIMIT, CONSTRUCT, and outer-binding isolation.

```sh
sh scripts/run-w3c-m5-subquery-tests.sh
```

For offline verification, set `W3C_M5_SUBQUERY_SUITE` to the cached
`sparql/sparql11/subquery` directory.

`scripts/run-m5-subquery-values-tests.sh` separately runs a local SubSelect
fixture with its grammar-defined final `VALUES` clause. It exercises parser,
algebra, evaluation, and ordered SRX comparison; this is release-gated local
semantic coverage, not a W3C manifest claim.

```sh
sh scripts/run-m5-subquery-values-tests.sh
```

`scripts/run-m5-final-values-tests.sh` separately runs four local query-level
final `VALUES` fixtures. They verify `VALUES` follows solution modifiers,
joins after grouping and `HAVING`, and remains available to SELECT expressions.
This is release-gated local semantic coverage, not a W3C manifest claim.

```sh
sh scripts/run-m5-final-values-tests.sh
```

## M5 grouping and aggregates

`scripts/run-w3c-m5-aggregate-tests.sh` runs 38 pinned SPARQL 1.1
`aggregates` fixtures. They cover implicit and explicit grouping, `COUNT(*)`,
`HAVING`, DISTINCT COUNT/SUM/AVG, exact SUM/AVG promotion, an empty AVG,
MIN/MAX including empty inputs, aggregate-error-to-unbound propagation, SAMPLE,
and seven `GROUP_CONCAT` cases, including language tags, DISTINCT, an explicit
separator, and blank-property-list source patterns. They additionally cover
DISTINCT SAMPLE, both empty-input COUNT result forms, GRAPH-scoped COUNT,
multiple HAVING conditions, cast and `DATATYPE` grouping. It is the aggregate
conformance gate; the narrower
`run-w3c-m5-count-tests.sh` remains available for a quick COUNT-only check.

`scripts/run-m5-aggregate-expression-distinct-tests.sh` separately runs two
local computed-`DISTINCT` aggregate cases. They cover `COUNT`, `SUM`, and
`GROUP_CONCAT` over expression results whose lexical values must outlive their
individual evaluations; this is release-gated local ownership coverage, not a
W3C manifest claim.

`scripts/run-w3c-m5-aggregate-syntax-tests.sh` separately runs the five
negative aggregate-scope syntax fixtures (`agg08` through `agg12`) and the
aliased grouping-expression positive fixture (`agg08b`).

`scripts/run-w3c-m5-grouping-tests.sh` runs the complete six-entry SPARQL 1.1
`grouping` manifest: four evaluations for simple, unbound, expression, and
aliased expression keys, plus two invalid ungrouped-projection queries.

```sh
sh scripts/run-w3c-m5-aggregate-tests.sh
sh scripts/run-m5-aggregate-expression-distinct-tests.sh
sh scripts/run-w3c-m5-aggregate-syntax-tests.sh
sh scripts/run-w3c-m5-grouping-tests.sh
```

For offline verification, set `W3C_M5_AGGREGATES_SUITE` to the cached
`sparql/sparql11/aggregates` directory, or `W3C_M5_GROUPING_SUITE` to the
cached `sparql/sparql11/grouping` directory.

The checked-in aggregate gate deliberately excludes `agg-sum-02` and
`agg-avg-02`: their pinned `mixed2` values are `2E-1` and `2.2`, which sum to
`2.4` and average to `1.2`, while the respective SRX results assert `4.0E-1`
and `2.0E-1`.
It also excludes `agg-err-02`: that result demands canonical `xsd:double`
lexical `2.5E0`, whereas `agg-sum-distinct` and `agg-avg-distinct` in the same
pinned manifest demand non-canonical double lexicals `2100` and `1050`.
The runner compares RDF terms strictly and does not relax lexical identity to
turn this fixture-policy inconsistency into a conformance claim.

## M5 property paths

`scripts/run-w3c-m5-property-path-tests.sh` runs a thirty-five-fixture
property-path gate: all thirty-three `mf:entries` in the pinned SPARQL 1.1
manifest, plus the unlisted bounded `{0,1}` and `{0}` fixtures `pp05` and
`pp13`. It covers forward and inverse sequence (`pp01`, `pp03`,
`pp08`, `pp09`, `pp11`), alternative precedence and multiplicity (`path-p1`
through `path-p4`), negated property sets (including `nps_a_inverse`),
closure over cycles and diamonds (`pp02`, `pp12`, `pp14`, `pp16`, `pp21`,
`pp23`, `pp25`, `pp37`), optional sequence (`pp28a`), bound endpoints
(`pp36`), VALUES composition, named-graph isolation (`pp06`, `pp07`, `pp34`,
`pp35`), and empty-graph identity cases. The executor lowers the
BGP-equivalent forms directly and evaluates the remaining forms through a
deduplicating path operator. `{n}`, `{n,m}`, and `{n,}` are implemented,
including nested blank-property-list and RDF-collection patterns. Those
bounded-range extensions are outside the pinned SPARQL 1.1 manifest.

`scripts/run-m5-bounded-path-extension-tests.sh` separately runs three local,
offline fixtures for `{2}`, `{1,2}`, and `{2,}` over a cyclic graph. They
exercise exact and inclusive finite ranges plus open-range duplicate
suppression. This is an extension compatibility gate, not a W3C claim.

```sh
sh scripts/run-w3c-m5-property-path-tests.sh
sh scripts/run-m5-bounded-path-extension-tests.sh
```

For offline verification, set `W3C_M5_PROPERTY_PATH_SUITE` to the cached
`sparql/sparql11/property-path` directory.

## M6 CONSTRUCT

`scripts/run-w3c-m6-construct-tests.sh` runs five SPARQL 1.1 CONSTRUCT
evaluation fixtures: `constructwhere01` through `constructwhere04` and
`constructlist`. It also runs the two CONSTRUCT-specific negative syntax
fixtures: `constructwhere05` rejects `FILTER` and `constructwhere06` rejects
`GRAPH` in the `CONSTRUCT WHERE` shortcut form. Expected Turtle graph outputs
are compared through RDF graph isomorphism,
including RDF blank-node identity rules rather than lexical labels. The runner
normalizes parser-private blank-node labels before calling the canonicalizer,
so comparison does not depend on N-Quads serializer label grammar.
`constructwhere04` receives a file-URI query base and a matching already-loaded
named graph; it verifies relative-IRI `FROM` resolution without network I/O.

```sh
sh scripts/run-w3c-m6-construct-tests.sh
```

`scripts/run-m6-construct-modifier-tests.sh` separately runs three local
grouped CONSTRUCT fixtures. They verify GROUP BY/HAVING, aggregate
ORDER BY/LIMIT, and final `VALUES` after aggregate HAVING are applied before
template instantiation, with graph-isomorphism comparison. This is a
release-gated semantic check, not a W3C manifest claim.

```sh
sh scripts/run-m6-construct-modifier-tests.sh
```

For offline verification, set `W3C_M6_CONSTRUCT_SUITE` to the cached
`sparql/sparql11/construct` directory.

`scripts/run-w3c-sparql10-construct-tests.sh` separately runs all five SPARQL
1.0 CONSTRUCT entries: identity, subgraph, two reification forms, and an
OPTIONAL template. The first reification form is a standalone blank-property
list template, and all expected graphs use isomorphism comparison.

```sh
sh scripts/run-w3c-sparql10-construct-tests.sh
```

For offline verification, set `W3C_SPARQL10_CONSTRUCT_SUITE` to the cached
`sparql/sparql10/construct` directory.

## M6 SPARQL Results JSON

`scripts/run-w3c-m6-json-result-tests.sh` runs all four fixtures in the pinned
SPARQL 1.1 `json-res` manifest: two `SELECT *` result sets and two `ASK`
results. It serializes the engine result using `sparql/results`, parses both
JSON documents, preserves `head.vars` order, and compares blank-node labels by
one-to-one mapping rather than by their serializer-local names.

```sh
sh scripts/run-w3c-m6-json-result-tests.sh
```

For offline verification, set `W3C_M6_JSON_RESULT_SUITE` to the cached
`sparql/sparql11/json-res` directory.

## M6 SPARQL Results CSV and TSV

`scripts/run-w3c-m6-csv-tsv-result-tests.sh` runs all six fixtures in the
pinned SPARQL 1.1 `csv-tsv-res` manifest. It checks CSV lexical cells and
escaping plus TSV RDF-term syntax, including unbound cells and blank nodes.

```sh
sh scripts/run-w3c-m6-csv-tsv-result-tests.sh
```

For offline verification, set `W3C_M6_CSV_TSV_RESULT_SUITE` to the cached
`sparql/sparql11/csv-tsv-res` directory.

## M6 SPARQL Results XML

`scripts/run-m6-xml-result-tests.sh` runs three local fixtures through the
external basic runner: one SELECT result containing IRI, plain, language, and
typed literals, plus true and false ASK results. It compares generated XML
exactly except for a fixture file's terminal newline. This is a release-gated
format compatibility check, not a W3C claim; the pinned test revision has no
separate XML-results manifest.

```sh
sh scripts/run-m6-xml-result-tests.sh
```

## M6 graph-result serialization

`scripts/run-m6-graph-result-tests.sh` runs local `CONSTRUCT` and `DESCRIBE`
fixtures through the external runner's N-Triples and Turtle output modes. All
four outputs are byte-exactly checked for IRI, plain, language, and typed
literals. This is a release-gated serializer compatibility check, not a W3C
claim.

```sh
sh scripts/run-m6-graph-result-tests.sh
```

## M6 DESCRIBE policy

SPARQL leaves DESCRIBE graph construction implementation-defined, so there is
no corresponding W3C evaluation gate. The repository instead pins its concise
default-graph policy with eleven local end-to-end graph fixtures. They cover
direct and variable targets, `DESCRIBE *`, an explicit target with no WHERE
solution, a declared `FROM` graph, and ordered `LIMIT`/`OFFSET` selection of
variable-derived targets while retaining explicit IRI targets. They also cover
`GROUP BY/HAVING`, aggregate `ORDER BY`, and final `VALUES` after aggregate
HAVING before target collection:

```sh
sh scripts/run-m6-describe-policy-tests.sh
```

## M7 SERVICE

`scripts/run-w3c-m7-service-tests.sh` runs every entry in the pinned SPARQL
1.1 `service` manifest. Its `--service` runner mode maps manifest-declared
endpoint data to application-owned local Dataset views through the explicit
SERVICE callback; it never opens a connection. The seven fixtures cover
constant and variable endpoints, OPTIONAL/nested SERVICE, VALUES, and SERVICE
SILENT with the standard empty SRX binding representation for an unbound
variable.

```sh
sh scripts/run-w3c-m7-service-tests.sh
```

For offline verification, set `W3C_M7_SERVICE_SUITE` to the cached
`sparql/sparql11/service` directory.
