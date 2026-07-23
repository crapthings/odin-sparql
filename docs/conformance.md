# Conformance policy

`odin-sparql` will claim only capabilities exercised by a pinned revision of
the official W3C RDF and SPARQL test repository. The suite is a test input, not
a production dependency, and release verification must not fetch it from the
network.

## Current state

M1 pins `w3c/rdf-tests` at `d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86`; its
SPARQL 1.1 Query syntax fixture is
`sparql/sparql11/syntax-query/manifest.ttl`. The provenance and fetch protocol
are recorded in `tests/w3c/README.md` and `scripts/fetch-w3c-tests.sh`.

The checked-in `scripts/run-w3c-syntax-tests.sh` runner passes the complete
pinned manifest: 63 `PositiveSyntaxTest11` entries and 31
`NegativeSyntaxTest11` entries. This verifies only Query syntax acceptance and
rejection by the pre-1.0 parser; it is not a claim of SPARQL query evaluation
conformance or a stable public API.

The separate M1 I18N gate passes all five entries from the pinned SPARQL 1.0
`i18n` manifest. It verifies Unicode prefixed names, wide Unicode whitespace,
and distinct normalized/non-normalized Unicode IRI spellings. Its three
relative-IRI fixture documents are loaded with their official I18N document
base; queries and expected result graphs remain unmodified.

M2/M5 now pass all 27 entries from the pinned SPARQL 1.0 `basic` evaluation
manifest through a Turtle-loaded in-memory Dataset and unordered SRX
result-multiset comparison. The four `list-*` entries exercise empty,
single-item, variable-item, and two-item RDF collection lowering in source
query patterns. This is a scoped Basic-manifest gate, not a claim to full
SPARQL query-evaluation conformance.

The separate M2 Triple Match gate passes all four entries in the pinned SPARQL
1.0 `triple-match` manifest. It verifies fixed-term matching, repeated-variable
compatibility within one triple pattern, and shared-variable joins across two
patterns. The fourth fixture contains a relative IRI in its Turtle data; the
runner supplies the manifest's document base while loading that data, without
changing the query or expected result.

The separate one-entry SPARQL 1.0 `bnode-coreference` manifest gate verifies
that a query result preserves a dataset blank node's co-reference across
multiple bindings. The result comparator establishes a one-to-one blank-node
mapping between actual and expected result documents, so source-local labels
are not treated as identities.

A separate M2 ASK gate passes all four entries from the pinned SPARQL 1.0
`ask` manifest. It verifies true and false ASK results for a fixed triple,
variable binding, and FILTER through the standard SPARQL XML boolean-result
format.

The in-progress M3 evaluator passes the eight `values01` through `values08`
entries from the pinned SPARQL 1.1 `bindings` manifest. The gate covers inline
and trailing `VALUES`, multi-column rows, `UNDEF`, joins, and one `OPTIONAL`
interaction through Turtle-loaded default-graph data and unordered SRX result
multiset comparison. A second M3 gate passes six SPARQL 1.0 OPTIONAL/UNION
entries (`q-opt-1` through `q-opt-3` and `q-opt-complex-1` through
`q-opt-complex-3`) and two SPARQL 1.1
MINUS entries (`full-minuend`, `part-minuend`), comparing both SRX and standard
RDF/Turtle result-set encodings. It additionally covers BIND arithmetic,
joins, filtering, UNION, error, and scope behavior in `bind01` through
`bind08`, `bind10`, and `bind11`, plus the complete seventeen-case SPARQL 1.0
GRAPH manifest:
default-graph isolation, GRAPH-variable lookup, UNION and joins, duplicate
data in distinct named graphs, empty graph patterns, explicit named-graph
existence, graph-variable joins, and graph-variable scope through a nested
OPTIONAL. It also passes three FILTER equality cases (`query-eq-3` through
`query-eq-5`) and all twelve entries from the SPARQL 1.0 Dataset manifest,
covering `FROM`, `FROM NAMED`, default-graph merging, named-graph restriction
against application-provided graphs, blank-node scope across duplicate graph
sources, and multi-source default/named graph composition.
`q-opt-complex-4` remains outside the gate because its official expected Turtle
uses a trailing semicolon in a nested blank property list that the pinned
`odin-rdf` Turtle reader rejects; this is an upstream RDF-reader compatibility
gap, not a rewritten test fixture.

The separate M3 Algebra gate passes all fourteen entries from the pinned
SPARQL 1.0 `algebra` manifest. It verifies nested OPTIONAL evaluation,
OPTIONAL-local and nested FILTER scope, group-local filter placement, variable
scope across joins, and combined JOIN/OPTIONAL/UNION/GRAPH relations. Its
fixture loader supplies the manifest's `http://example/` document base for
relative data IRIs and constructs the one declared named graph; it does not
modify any query or expected result.

The complete fifteen-entry pinned SPARQL 1.0 `expr-equals` manifest passes.
It verifies integer/decimal and floating numeric promotion plus string/IRI,
boolean, and normalized `xsd:dateTime` equality in `FILTER`, two-variable
value equality, and the five graph-term-equality variants. The pinned
`eq-2-2` entry references the same query and expected result as `eq-2-1`, so
the official gate executes it verbatim but does not treat it as independent
`!=` coverage. Decimal arithmetic and special floating values remain separate
M4 gates. A second M4 gate passes `ge-1` and `le-1` from the pinned
SPARQL 1.0 `expr-ops` manifest, covering numeric `>=` and `<=` in `FILTER`.
The same comparison gate passes all four `xsd:dateTime` relation entries
(`dateTime-le-2`, `dateTime-ge-2`, `dateTime-lt-2`, and `dateTime-gt-2`),
covering timezone-qualified, timezone-absent, and mixed inputs. The M4 boolean
gate passes `expr-4` from the pinned SPARQL 1.0
`optional-filter` manifest, exercising `&&` inside an OPTIONAL-scoped FILTER.
The same gate also passes `expr-3`, exercising `BOUND` plus `||` for an
unbound OPTIONAL variable.
The dedicated M4 BOUND gate passes the sole entry in the pinned SPARQL 1.0
`bound` manifest, confirming direct `BOUND` filtering over a graph-pattern
binding independently of OPTIONAL boolean composition.
The M4 effective-boolean-value gate passes all seven entries from the pinned
SPARQL 1.0 `boolean-effective-value` manifest. It verifies truth and falsehood
for boolean, numeric, and string literals; `&&`/`||`; and error propagation
for unbound values and unknown datatypes.
The M4 unary-numeric gate passes all four `unplus-1`, `unminus-1`,
`unplus-2`, and `unminus-2` entries from the pinned SPARQL 1.0 `expr-ops`
manifest.
The M4 arithmetic gate passes `plus-1`, `minus-1`, `mul-1`, `add-literals`,
`add-numbers-cast`, `subtract-numbers-cast`, `multiply-numbers-cast`, and
`divide-numbers-cast` from the same manifest. The four mixed-type fixtures
each verify all sixteen integer/decimal/float/double type-promotion
combinations. The M4 type-promotion gate passes all thirty entries from the
pinned SPARQL 1.0 `type-promotion` manifest. It verifies the full XML Schema
integer-derived numeric family (`byte` through `unsignedLong`), promotion to
the integer/decimal/float/double value spaces, and the negative cases where a
comparison must remain false rather than coerce incompatible numeric types.
The four historic mixed-type arithmetic fixtures retain their original
integral-`xsd:decimal` result spellings; their gate compares only `6` and
`6.0`-style integral decimal spellings by value, while all other RDF terms and
all non-integral decimals remain exact.
The M4 built-in gate passes twenty-four entries from the pinned SPARQL 1.0
`expr-builtin` manifest: all three `sameTerm`, four `STR`, all three `LANG`,
three `DATATYPE`, one each for `isBlank`, `isIRI`, and `isURI`, five
`langMatches` cases, case-insensitive language-tag equality/inequality, and
case-insensitive boolean keyword canonicalization. Its result
comparator performs a one-to-one mapping for blank nodes from the two result
documents. `isLiteral` has engine unit coverage but is not yet a W3C gate:
its official Turtle result fixture uses a trailing semicolon in a nested blank
property list, which the pinned `odin-rdf` Turtle reader currently rejects.
This is tracked as an upstream RDF-reader compatibility gap rather than being
silently rewritten by the SPARQL test runner.

The M4 open-world gate passes eighteen direct-comparison entries from the
pinned SPARQL 1.0 `open-world` manifest: `open-eq-01` through `open-eq-12`,
plus `open-cmp-01` and `open-cmp-02`. It verifies that identical unsupported
or ill-typed literals compare equal while distinct unknown datatype literals
remain expression errors, language-string comparisons do not infer unsupported
datatype values, and an OPTIONAL-local `!= || =` filter receives correlated
left-side bindings. It also passes all four `xsd:date` entries (`date-1`
through `date-4`): valid calendar/timezone lexical forms, timezone-absence
behavior in equality, date relations, and `DATATYPE`. This is not a general
temporal claim: temporal ordering and other date/time casts remain deferred.

The M4 regex gate passes seventeen SPARQL 1.0 `regex` manifest entries with
SRX results. It covers quantifiers, character classes, anchors, the `i`, `m`,
`s`, `x`, and manifest-specific `q` flags, and default-dot versus dot-all
newline behavior. The four historic `regex-query-001` through
`regex-query-004` cases are not counted in that gate: their expected results
are Turtle result sets rejected by the pinned `odin-rdf` Turtle reader for the
same trailing-semicolon form recorded above. They are not rewritten or claimed
as passing tests.

The M4 core-function gate passes `in01`, `in02`, `notin01`, `isnumeric01`,
`if01`, `if02`, the empty-argument error case for `COALESCE`, and the four `CONCAT`
cases from the pinned SPARQL 1.1 `functions` manifest. These cover successful
and unsuccessful value-equality membership, the empty-list rule for `NOT IN`,
numeric literal classification, a successful `IF` projection and an error-
condition `IF` that leaves its binding unbound, the all-error behavior of
`COALESCE`, string/language-tag concatenation, and `STRSTARTS`,
`STRENDS`, `CONTAINS`, plus BMP and non-BMP `STRLEN` code-point counting. The
same gate also passes `notin02`, verifying that a later equality match
suppresses an earlier division-by-zero expression error.
It additionally passes `plus-1-corrected` and `plus-2-corrected`: numeric
addition preserves its promoted datatype and decimal lexical precision (with
an integral decimal retaining `.0`), while
`str(...) + str(...)` is an expression error that leaves its
projected result unbound. It also passes `coalesce01`, including `0.0` and
`2.0` decimal results. Result multiset comparison maps document-local blank
nodes one-to-one, so the `plus-1-corrected` blank-node row is covered.
The same gate also passes the official `STRBEFORE` and `STRAFTER` language-tag
preservation and incompatible-language error cases (`strbefore01a`,
`strafter01a`, `strbefore02`, `strafter02`).
The separate four-vector case-function gate passes `LCASE` and `UCASE` over
both the approved baseline data and the proposed non-BMP input vectors; it
preserves language tags and applies Unicode code-point mappings.
The separate `now01` gate verifies that `NOW()` yields an `xsd:dateTime`;
its runner injects a fixed query clock for reproducible fixture execution.
The separate UUID gate passes `uuid01`, `struuid01`, and `uuid02`, verifying
the `urn:uuid:` IRI form, the 36-character string form, and fresh values from
two invocations. Production UUID generation uses a cryptographically secure
v4 source; `engine.Options.UUID_Callback` is the explicit deterministic
execution boundary.
The separate `rand01` gate verifies an `xsd:double` in `[0,1)` from `RAND()`;
`engine.Options.RAND_Callback` is its deterministic execution boundary.
The eight-vector temporal-function gate passes `YEAR`, `MONTH`, `DAY`,
`HOURS`, `MINUTES`, `SECONDS`, `TIMEZONE`, and `TZ` over the approved SPARQL
1.1 dateTime fixtures, including an absent timezone represented as an unbound
`TIMEZONE` and an empty-string `TZ` result.
The four-vector `REPLACE` gate passes global non-overlapping replacement,
language-tag preservation, overlapping-pattern behavior, capture expansion
with an unmatched alternative group, and the case-insensitive flag.
It additionally passes `strdt01`, `strdt02`, and the RDF 1.1 type-error case
`strdt03-rdf11`.
It also passes `strlang01`, `strlang02`, and the RDF 1.1 type-error case
`strlang03-rdf11`, including case-insensitive language-tag identity in result
comparison and query evaluation.
The same gate also passes `bnode01` and `bnode02`: string arguments preserve
the same generated blank node only within one solution mapping, while
zero-argument calls are fresh. Generated nodes use a query-private RDF blank
node scope and survive result materialization.
It also passes the BMP and non-BMP `encode01` `ENCODE_FOR_URI` fixtures,
including UTF-8 byte encoding and language-tag removal from the result.
It also passes the one- and two-argument BMP and non-BMP `SUBSTR` fixtures,
including code-point rather than UTF-8-byte indexing and language-tag
preservation.
The same gate passes both standard and Unicode-input vectors for `MD5`,
`SHA1`, `SHA256`, `SHA384`, and `SHA512` (ten fixtures total).
The same gate also passes the exact-integer/decimal `abs01`, `ceil01`,
`floor01`, and `round01` cases. Focused local coverage extends those functions
to `xsd:float` and `xsd:double`, including preserved result width, `NaN`,
infinities, and SPARQL's negative-half rounding rule; the pinned fixtures only
exercise exact numeric inputs.
It additionally passes `iri01` and `iri02`, covering both `URI` and `IRI`
with string and IRI-reference inputs resolved against a query BASE.

The M4 solution-modifier gate passes six entries from the pinned SPARQL 1.0
`distinct` manifest: numeric, string, blank-node, OPTIONAL, mixed-data, and
`SELECT *` projections. The separate M4 `REDUCED` gate passes both entries
from its pinned SPARQL 1.0 manifest. The runner implements that manifest's
`mf:LaxCardinality` rule exactly for its blank-node-free fixtures: every actual
mapping is an expected mapping and cannot exceed its expected multiplicity,
while every distinct expected mapping remains represented. The engine uses
complete deduplication, which is one permitted `REDUCED` outcome.

The separate M4 Solution Sequence gate passes all thirteen entries from the
pinned SPARQL 1.0 `solution-seq` manifest. It covers four `LIMIT`, four
`OFFSET`, and five combined slice cases, each over an ordered solution
sequence. This independently proves that slicing occurs after `ORDER BY`.

A local five-case M4 ASK modifier gate verifies that modifiers change the
boolean after pattern evaluation: ordered OFFSET/LIMIT can yield both true and
false, GROUP BY/HAVING can select or reject the sole group, and LIMIT 0 yields
false. It is a release-gated semantic check through standard SRX boolean
results, not a W3C manifest claim.

The M4 projection-expression gate passes all seven entries from the pinned
SPARQL 1.1 `project-expression` manifest. It covers projected arithmetic and
equality aliases, reuse by a later projection expression and `ORDER BY`, and
ordinary expression errors represented by an unbound projected variable.

The M4 scalar-cast gate passes all seven entries from the pinned SPARQL 1.0 `cast`
manifest: `xsd:integer`, `xsd:decimal`, `xsd:boolean`, `xsd:string`,
`xsd:float`, `xsd:double`, and `xsd:dateTime`. The latter validates the
accepted string lexical form and assigns the requested datatype without
silently canonicalizing its lexical spelling. Focused local coverage extends
that same strict constructor policy to `xsd:date` and `xsd:time`, including
calendar/clock validation, timezone spellings, `24:00:00`, language-tag
rejection, and cross-temporal-type errors; the pinned SPARQL 1.0 cast manifest
has no corresponding date/time vectors.

The M4 negation gate passes all ten SPARQL 1.1 manifest fixtures: `exists-01`, `exists-02`,
`subsetByExcl01`, `subsetByExcl02`, `temporalProximity01`, `subset-01` through
`subset-03`, `set-equals-1`, and `graph-minus`. They verify seeded correlated
`EXISTS` and `NOT EXISTS`, MINUS-based set exclusion, a temporal exclusion,
nested MINUS, lexical `STR` comparison, and named-graph MINUS disjointness.

The complete six-entry SPARQL 1.1 `exists` manifest is separately gated:
default-graph constants and ground triples, nested positive and negative
existence, an active named-graph scope, and a graph variable already bound by
the outer solution. Correlated existence therefore evaluates its nested pattern
in the same graph scope as the enclosing expression.

The M5 subquery gate passes seven SPARQL 1.1 `subquery` fixtures: `sq08` through
`sq14`, excluding the RDF/XML-fixture-dependent `sq01` through `sq07`. They
verify a subquery aggregate, nested `SELECT *` projection boundaries, the
interaction between a subquery result and a correlated `EXISTS` filter,
subquery-local LIMIT, CONSTRUCT with a subquery, and non-injection of outer
bindings. `sq01` through `sq07` depend on `sq01.rdf` or `sq05.rdf`, whose
`rdf:resource=""` relative IRI is rejected by the pinned `odin-rdf` RDF/XML
reader; this is recorded as an upstream reader compatibility gap rather than a
rewritten fixture. Subquery dataset clauses are not part of the SPARQL
SubSelect grammar; the parser rejects `FROM`/`FROM NAMED` at their source span
with `Invalid_Query` instead of accepting a query the algebra would reject.
The separate local M5 SubSelect final VALUES gate verifies the grammar's one
optional trailing VALUES clause through parser, algebra, evaluation, and
ordered SRX comparison. Repeated final VALUES clauses are rejected at parser
scope; this is release-gated but not a W3C manifest claim.
The separate four-case query-level final VALUES gate verifies that a clause
following `HAVING` is parsed at that grammar position and joins after grouping
and `HAVING`, before SELECT expressions. Its aggregate fixture prevents an
early join from changing `COUNT` or discarding a group; this is release-gated
local semantic coverage, not a W3C manifest claim.

The M5 aggregate gate passes 38 SPARQL 1.1 `aggregates` fixtures: `agg01`
through `agg07`, both DISTINCT COUNT cases, `agg-sum-01`,
`agg-sum-distinct`, `agg-avg-01`, `agg-avg-03`, `agg-avg-distinct`, the three
MIN cases, the three MAX cases, and `agg-sample-01`. They cover implicit and
explicit groups, `COUNT(expression)`, `COUNT(*)`, DISTINCT aggregation,
aggregate `HAVING`, exact numeric promotion, empty AVG, and canonical floating
result terms selected by MIN/MAX/SAMPLE. It also passes `agg-err-01`, which
keeps the type-error group while leaving its aggregate-derived output bindings
unbound, plus both empty-input MAX cases. It also passes `agg-groupconcat-1`
through `agg-groupconcat-6` and `agg-groupconcat-distinct`, covering
blank-property-list source patterns, language tags, DISTINCT, and an explicit
separator. It additionally covers DISTINCT SAMPLE, both empty-input COUNT
result forms, GRAPH-scoped COUNT, multiple HAVING conditions, cast and
`DATATYPE` grouping. A separate
six-case syntax gate passes the aggregate-scope negative
fixtures `agg08` through `agg12` and the aliased grouping-expression positive
fixture `agg08b`: non-variable group expressions require an explicit alias
before the key can be projected.
The separate two-case local computed-`DISTINCT` gate evaluates `COUNT`, `SUM`,
and `GROUP_CONCAT` over computed terms, ensuring their deduplication keys
remain valid after each expression result is released. This is release-gated
memory-lifetime coverage, not a W3C manifest claim.

The complete six-entry SPARQL 1.1 `grouping` manifest is also gated: four
evaluation fixtures cover simple, unbound, expression, and aliased expression
keys, while `group06` and `group07` reject ungrouped projections. In
particular, an aliased key is materialized into the output binding rather than
being used only to partition input solutions.

`agg-sum-02` is intentionally excluded: its fixed input has `mixed2` values
`2E-1` and `2.2`, while the expected result asserts `4.0E-1` rather than their
numeric sum, `2.4`. `agg-avg-02` is likewise excluded: those same values have
the numeric average `1.2`, while its expected result asserts `2.0E-1`. These
are recorded fixture-data/expected-result contradictions, not passing
conformance claims. `agg-err-02` is also intentionally excluded from the
strict term-comparison gate: it requires canonical `xsd:double` lexical
`2.5E0`, while the same pinned manifest's `agg-sum-distinct` and
`agg-avg-distinct` require non-canonical double lexicals `2100` and `1050`.
The evaluator preserves the ordinary floating-operation lexical form, so it
cannot satisfy both requirements through one consistent result-term policy.
This is a fixture lexical-policy inconsistency, not a value-space or aggregate
evaluation failure.

The M5 property-path gate passes all thirty-three `mf:entries` in the pinned
SPARQL 1.1 manifest, plus the unlisted bounded `{0,1}` and `{0}` fixtures
`pp05` and `pp13`. It covers forward/inverse sequence, alternatives including
duplicate-preserving sequences, negated property sets, cyclic diamond and loop
traversal, `VALUES` composition, bound endpoints, named-graph isolation, and
empty-graph identity for `*` and `?` paths.
Inverse and sequence forms compile to BGP triples where possible. The other
forms use a dedicated path operator with path-local duplicate suppression; its
engine coverage also verifies named-graph isolation. Bounded path ranges
`{n}`, `{n,m}`, and `{n,}` are supported with path-local endpoint
deduplication, including paths nested inside blank-property lists and RDF
collections. These bounded-range extensions are outside the pinned SPARQL 1.1
property-path manifest.

The separate local bounded-path extension gate covers `{2}`, `{1,2}`, and
`{2,}` against one cyclic graph, including inclusive finite bounds and
duplicate suppression after the open lower bound. It is release-gated through
the same external basic-runner path as W3C result fixtures, but is explicitly
not counted as W3C conformance because the official pinned manifest has no
entries for these extensions.

The initial M6 CONSTRUCT gate passes five evaluation entries:
`constructwhere01` through `constructwhere04` plus `constructlist` from the
SPARQL 1.1 `construct` manifest. It also passes the manifest's two
CONSTRUCT-specific negative syntax entries: `constructwhere05` (FILTER) and
`constructwhere06` (GRAPH) are invalid in the `CONSTRUCT WHERE` shortcut
form. The evaluation runner parses the expected Turtle graph and compares RDF
graph isomorphism using the pinned `odin-rdf` canonicalizer, so statement order
and blank-node labels are not observable. It normalizes parser-private
blank-node labels before canonicalization because those labels need not be
valid N-Quads surface labels. `constructwhere04` uses a file-URI query base and
a matching application-provided named graph to test relative-IRI `FROM`
resolution without loading a resource. Engine coverage additionally proves
template blank-node freshness per solution and shared labels within one
solution, `FROM`/`FROM NAMED` query-dataset selection, and `ORDER BY`,
`LIMIT`, and `OFFSET` before template instantiation.

A separate local three-case M6 CONSTRUCT modifier gate compares graph-isomorphic
output for GROUP BY/HAVING, aggregate ORDER BY/LIMIT, and final VALUES after
aggregate HAVING. It proves these solution modifiers run before template
instantiation and is release-gated through the external basic runner; it is
not a W3C manifest claim.

The separate M6 SPARQL 1.0 CONSTRUCT gate passes all five entries from its
pinned `construct` manifest. It verifies graph identity and subgraph templates,
reification using both an explicit template blank label and a standalone blank
property list, plus OPTIONAL omission of an unbound template variable. Expected
graphs are compared by RDF graph isomorphism.

The M6 SPARQL Results JSON gate passes all four entries in the pinned SPARQL
1.1 `json-res` manifest: two `SELECT *` result sets and true/false `ASK`
results. The runner serializes the owned engine result through `sparql/results`
then compares parsed JSON structure, including the ordered `head.vars` list and
a one-to-one mapping of blank-node labels. This verifies result-format semantics
without depending on JSON object-member ordering. In particular, top-level
`SELECT *` columns are retained in source-variable order rather than incidental
internal binding-allocation order.
The separate M6 CSV/TSV gate passes all six entries in the pinned SPARQL 1.1
`csv-tsv-res` manifest: ordinary terms, unbound OPTIONAL cells, CSV quoting,
typed-literal preservation in TSV, and deterministic result-local blank-node
labels.

The separate local M6 XML-result gate serializes SELECT bindings containing an
IRI plus plain, language, and typed literals, then true and false ASK results.
It compares the XML document body exactly through the external basic runner;
only a fixture file's terminal CR/LF is ignored. The pinned fixture revision
has no standalone XML-results manifest, so this is release-gated format
compatibility evidence rather than a W3C conformance claim.

The local M6 graph-result serialization gate runs both `CONSTRUCT` and the
documented concise `DESCRIBE` result through the public N-Triples and Turtle
writers in the external runner. Its four byte-exact fixtures cover IRI, plain,
language, and typed literals; this is release-gated serializer compatibility
evidence, not a W3C format claim.

DESCRIBE has no W3C query-evaluation manifest because its graph-construction
algorithm is implementation-defined. The eleven-case local M6 DESCRIBE policy
gate therefore makes no W3C conformance claim: it verifies this library's
documented concise default-graph policy for direct IRI targets, explicit IRIs
with no WHERE solution, variable targets, `DESCRIBE *` target discovery, and
a variable blank-node target selected through a declared `FROM` graph. Its
three non-aggregate modifier cases verify ordered LIMIT selection, ordered
OFFSET/LIMIT selection, and that an explicit IRI target is unaffected by the
sliced WHERE solution sequence. Three aggregate cases verify GROUP BY/HAVING,
aggregate ORDER BY/LIMIT, and final VALUES after HAVING before target
selection.

M7 passes all seven entries from the pinned SPARQL 1.1 `service` manifest.
The offline runner maps each fixture's declared `qt:serviceData` endpoint
document into the explicit application callback, covering ordinary and
variable endpoints, OPTIONAL and nested SERVICE patterns, VALUES interaction,
and `SERVICE SILENT` with an unavailable endpoint. It also accepts the standard
empty SRX binding element as an explicitly unbound variable. This is a
federated-query semantics claim, not a SPARQL protocol, endpoint-discovery, or
network implementation claim: the core does not open connections, serialize
protocol requests, or implement HTTP authentication and retry behavior.

The M4 ordering gate passes fourteen applicable entries from the pinned SPARQL
1.0 `sort` manifest: ascending and descending strings, optional/unbound IRI
keys, exact numeric and mixed numeric ordering, broad blank-node/IRI/literal
categories, multiple keys, expression keys, `STR` keys, and a key not exposed
by SELECT projection. The shared runner reads historic RDF/XML result-set
files and honors `rs:index` for ordered Turtle result sets. The SPARQL 1.0
`sort-11` fixture is excluded: it asserts an ordering distinction between
plain literals and `xsd:string`, but RDF 1.1 (and therefore `odin-rdf`) treats
them as the same literal form. The cast-based `sort-function` entry is now
covered by this gate through `xsd:integer()`.

Focused engine coverage additionally verifies `ORDER BY` over validated
`xsd:dateTime` values, including normalized explicit offsets and stable order
for equal instants. This is local coverage because the pinned sort manifest
does not provide a corresponding temporal vector. The same local suite covers
`xsd:time` value equality, relations, and ordering with normalized offsets.

## Gate rules

- Syntax gates run positive and negative Query syntax manifests separately.
- Evaluation gates run only after their parser and algebra capabilities exist.
- Every omitted or unsupported manifest entry has a reason in a checked-in
  conformance ledger; passing a hand-picked subset is not a conformance claim.
- Expected result comparison must preserve SPARQL result ordering rules,
  multiset cardinality, unbound bindings, and RDF graph isomorphism where
  applicable.
- Update, protocol, service-description, and entailment manifests are separate
  gates. They do not become supported incidentally through query parsing.
