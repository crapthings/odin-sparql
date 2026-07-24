# Changelog

This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

## 0.1.2 - 2026-07-24

- Add release-gated `Memory_Dataset` regressions for blank-node scope,
  case-folded language-tag identity, set deduplication, and scoped scans. No
  public API or query-execution behavior changes.

## 0.1.1 - 2026-07-24

- Publish a documentation-only pre-1.0 patch that aligns the generated Pages
  site with the Odin RDF visual palette. Query parsing, Dataset behavior,
  execution semantics, public APIs, and compatibility expectations are
  unchanged from `0.1.0`.

## 0.1.0 - 2026-07-24

- First public release of the bounded, dataset-agnostic SPARQL 1.1 Query
  parser and execution engine. The stable pre-1.0 package surface is
  `sparql`, `sparql/dataset`, `sparql/engine`, and `sparql/results`; SPARQL
  Update, protocol/HTTP endpoints, graph storage, and entailment remain
  outside this release's scope.
- Prove from an external consumer package that `engine.Execution_Statistics`
  is usable without importing `sparql/eval`, and that its documented BGP scan,
  candidate, match, and solution counters accumulate through a custom View.
- Expand the deterministic parser-fuzz seed corpus through Dataset clauses,
  SERVICE, final VALUES, grouping/HAVING, bounded property paths, and DESCRIBE
  modifiers, so mutations exercise their public AST traversal branches.
- Add a runnable public `dataset.custom_view` example for application-owned
  RDF storage, including graph-scope matching and sink early-stop semantics.
  Run it in cross-platform CI and offline release verification alongside the
  in-memory example.
- Add optional distinct-quad and copied lexical-byte limits to `Memory_Dataset`
  through `init_with_options`. Capacity exhaustion is now a stable
  `Quad_Limit` or `Lexical_Limit` outcome that leaves the Dataset unchanged;
  the existing `init` API retains its memory-governed behavior.
- Add a runnable public minimal example covering RDF quad construction, sealed
  in-memory Dataset use, query parsing/execution, and SPARQL Results JSON
  serialization. Run it in the cross-platform CI lane and offline release
  verification so the documented public API path cannot drift.
- Fix the default `NOW()` execution context under optimized builds. Its
  generated UTC lexical form now lives in evaluator-owned stack storage rather
  than a temporary allocator, with a multi-pattern BGP regression and an
  optimized engine-test release gate.
- Make the BGP-planning benchmark executable under the documented process
  command by fixing its execution context: bounded solutions, numeric digits,
  and query clock. Its output now records those effective settings.
- Define the complete prepare/verify/publish release decision chain, including
  the explicit 1.0 API-freeze review, immutable annotated tag policy, and
  retained offline-verification evidence. Gate the documented `odin-rdf` and
  W3C fixture revisions against CI and offline release verification.
- Expand the W3C aggregate gate with empty-input COUNT, GRAPH-scoped COUNT,
  multiple HAVING, cast and `DATATYPE` grouping, and DISTINCT SAMPLE fixtures.
- Retain independently owned lexical values for computed `DISTINCT` aggregate
  keys, so `COUNT`, `SUM`, and `GROUP_CONCAT` do not retain expressions past
  their evaluation lifetime.
- Include focused AddressSanitizer checks for evaluator and engine ownership
  boundaries in offline release verification.
- Accept finite `xsd:float` and `xsd:double` `SUBSTR` indexes, applying the
  SPARQL half-toward-positive-infinity rule before bounded string slicing;
  reject non-finite indexes as expression errors.
- Retain owned computed group keys until their buckets are materialized, so
  cast and other expression-based grouping values cannot dangle.
- Cover the full computed-key lifetime through `VALUES`, grouping, aggregate
  materialization, and `ORDER BY` under AddressSanitizer.
- Apply a query-level final `VALUES` clause after grouping and `HAVING`, while
  retaining its bindings for SELECT expressions and ordering; parse this
  grammar position after solution modifiers and gate both behaviors locally.
- Parse and evaluate the grammar-defined final VALUES clause inside SubSelect,
  with external end-to-end regression coverage.
- Reject repeated final VALUES clauses at Query and SubSelect scope, matching
  the grammar's optional single ValuesClause.
- Reject DatasetClause in a SubSelect at parser scope, matching the SPARQL
  grammar instead of deferring an over-accepted query to algebra failure.
- Apply CONSTRUCT GROUP BY/HAVING and aggregate ORDER BY semantics before
  template instantiation, instead of silently ignoring those modifiers.
- Parse and execute ASK solution modifiers, including GROUP BY/HAVING,
  ORDER BY, OFFSET, and LIMIT, so they affect the returned boolean.
- Apply `DESCRIBE` ORDER BY/OFFSET/LIMIT modifiers to variable-derived targets
  under the documented concise graph policy, while retaining explicit IRI
  targets independently of the WHERE solution sequence.
- Apply `DESCRIBE` GROUP BY/HAVING and aggregate ORDER BY semantics before
  variable-derived targets are collected, instead of silently ignoring them.
- Add a release-gated external graph-result serialization suite for
  N-Triples and Turtle CONSTRUCT/DESCRIBE output.
- Add a release-gated external SPARQL Results XML suite for SELECT term kinds
  and true/false ASK documents.
- Export all execution callback types through `sparql/engine`, so callers do
  not need an implementation-package `sparql/eval` import to configure
  SERVICE, UUID, or RAND behavior.
- Add a release-gated local compatibility suite for `{n}`, `{n,m}`, and
  `{n,}` property-path extensions, covering exact/finite/open ranges and
  cyclic duplicate suppression outside the W3C manifest.
- Document the stable Dataset API boundary: sealed in-memory ownership and
  lifecycle, graph-scoped scan semantics, external adapter duties, and errors.
- Clarify parser diagnostics and result-serialization kind/error contracts,
  with external regressions for atomic wrong-kind writer failure.
- Define the intended stable package surface and explicitly keep algebra,
  evaluator, and internal packages outside the public compatibility promise.
- Distinguish invalid public execution options from unsupported queries:
  non-positive solution limits and invalid fixed `NOW()` values now return the
  stable `engine.Error_Code.Invalid_Options` outcome.
- Prove from an external consumer package that all six result serializers can
  safely consume owned SELECT or Graph results after their originating Query
  and Dataset have been destroyed.
- Canonicalize case-insensitive boolean keywords to `true` / `false` at the
  SPARQL-to-RDF value boundary, and expand the W3C SPARQL 1.0 `expr-builtin`
  gate from nineteen to twenty-four compatible manifest entries.
- Expand the W3C SPARQL 1.0 `expr-equals` gate from eight entries to its full
  fifteen-entry manifest, including two-variable and graph-term equality.
- Cover all eighteen entries in the W3C SPARQL 1.0 `expr-ops` manifest across
  comparison, unary-numeric, and arithmetic release gates.
- Gate the complete twelve-entry W3C SPARQL 1.0 Dataset manifest, including
  duplicate blank-node sources and multi-source default/named graph selection.
- Add atomic SPARQL Results CSV/TSV writers and gate all six W3C SPARQL 1.1
  `csv-tsv-res` fixtures, including typed terms, unbound cells, escaping, and
  result-local blank-node labels.
- Preserve top-level `SELECT *` source-variable order in `Plan` result-column
  metadata, and add a complete four-case W3C SPARQL 1.1 Results JSON gate with
  structural JSON and blank-node-label-independent comparison.
- Reject XML 1.0-forbidden characters atomically in the SPARQL Results XML
  writer, instead of emitting syntactically invalid XML from otherwise valid
  UTF-8 RDF terms.
- Add a complete seven-case offline W3C SPARQL 1.1 SERVICE gate by mapping
  fixture endpoint data through the explicit no-network callback boundary;
  accept empty SRX bindings as unbound result variables.
- Preserve operand decimal precision and integral `.0` in arithmetic and
  division results, and add the W3C SPARQL 1.1 `coalesce01` and
  blank-node-containing `plus-1-corrected` gates.
- Enforce SPARQL string-function language-tag compatibility for `STRBEFORE`,
  `STRAFTER`, `STRSTARTS`, `STRENDS`, and `CONTAINS`, and gate the four
  relevant official `STRBEFORE` / `STRAFTER` vectors.
- Fix `GROUP BY (expression AS ?alias)` API exposure and result materialization,
  then add the complete six-entry W3C SPARQL 1.1 `grouping` manifest gate.
- Preserve active named-graph scope through correlated `EXISTS` / `NOT EXISTS`
  evaluation and add the complete six-entry SPARQL 1.1 `exists` manifest gate.
- Add Unicode code-point `LCASE` / `UCASE` evaluation with language-tag
  preservation and four W3C SPARQL 1.1 BMP/non-BMP regression vectors.
- Run `sparql/results` tests in both normal and AddressSanitizer CI lanes, so
  graph and SPARQL-results serialization has the same continuous coverage as
  the execution core.
- Align the README and M6 design notes with the implemented query, SERVICE,
  graph-result, and release-gated CONSTRUCT surface.
- Strengthen fixed-seed parser fuzzing with intact valid-query seeds and
  recursive public-AST traversal invariants for terms, patterns, paths,
  expressions, VALUES, and subqueries.
- Add an offline complete four-case W3C SPARQL 1.0 `triple-match` gate for
  repeated-variable compatibility and shared-variable BGP joins.
- Add an offline complete thirteen-case W3C SPARQL 1.0 `solution-seq` gate
  for ordered `LIMIT`, `OFFSET`, and combined slice behavior.
- Correct nested OPTIONAL evaluation so inherited outer bindings do not
  constrain a nested `LeftJoin` relation before its enclosing compatibility
  merge; add the complete fourteen-case W3C SPARQL 1.0 `algebra` gate.
- Add a precise `mf:LaxCardinality` comparator for the pinned blank-node-free
  W3C `REDUCED` fixtures and gate both permitted complete-deduplication cases.
- Add a complete five-case W3C SPARQL 1.0 I18N gate for Unicode prefixed
  names, whitespace, and normalized/non-normalized IRI identity.
- Support standalone blank-property-list CONSTRUCT templates and add the
  complete five-case SPARQL 1.0 CONSTRUCT graph-isomorphism gate.
- Complete the SPARQL 1.0 GRAPH manifest gate with `graph-01`, the
  default-graph baseline fixture, raising the M3 graph-pattern total to 46.
- Add cooperative `engine.Options.Cancellation_Callback` / `Cancellation_Data`
  with a distinct `Cancelled` result. It is propagated through evaluation,
  Dataset scans, DESCRIBE expansion, and result materialization, with external
  package regression coverage for immediate, in-scan, and `SERVICE SILENT`
  cancellation. The first request is latched across nested evaluation so a
  one-shot cancellation cannot be folded into an ordinary expression error.
- Extend cooperative-cancellation polling through bounded in-memory relation
  loops, including VALUES, joins, UNION concatenation, FILTER/BIND, projection,
  DISTINCT, SLICE, ORDER, GROUP, graph-variable expansion, and correlated
  SERVICE evaluation.
- Extend cancellation through property-path edge scans, graph partitioning,
  and recursive sequence, alternative, closure, bounded-range, and negated-set
  traversal; a public regression fixes the path-scan cancellation boundary.
- Propagate cancellation through per-group aggregate member and DISTINCT loops
  for COUNT, SUM/AVG, GROUP_CONCAT, MIN/MAX, and SAMPLE, with external-package
  aggregate execution coverage.
- Fix `dataset.custom_view` as the public storage-adapter boundary with an
  external-package execution regression: application-owned `Scan_Proc`
  implementations preserve graph scope and successful sink early-stop without
  depending on `Memory_Dataset`.
- Distinguish invalid Dataset adapter inputs from an unsealed memory snapshot:
  `dataset.scan` now returns `Invalid_View` for a missing scan callback and
  `Invalid_Sink` for a nil sink, reserving `Sealed` for `Memory_Dataset`
  lifecycle errors.
- Added `dataset.add_collector`, an explicit copying ingestion adapter from
  `odin-rdf:rdf/dataset.Collector` into an unsealed `Memory_Dataset`.
- Add validated `xsd:date(...)` and `xsd:time(...)` scalar casts. They accept
  only eligible string or matching temporal literals, retain valid lexical
  spellings, and reject invalid, language-tagged, and cross-temporal inputs.
- Extend `ABS`, `CEIL`, `FLOOR`, and `ROUND` to `xsd:float` and `xsd:double`,
  retaining the source floating datatype and SPARQL's half-toward-positive-
  infinity rule.
- Expand the pinned core-function gate with `if02` and `plus-2-corrected`,
  covering error-to-unbound behavior in `IF` and string addition.
- Document the proposed stable query-execution API and add an external-package
  public API regression suite for result ownership and form-specific accessors.
- Add opt-in deterministic BGP ordering, caller-owned execution statistics,
  and a reproducible source-versus-planned query benchmark; the default remains
  source order and no storage/index dependency is introduced.
- Add a fixed-seed generated-dataset property gate for BGP ordering multiset
  equivalence and run it in normal and AddressSanitizer CI lanes.
- Add configurable deterministic parser fuzzing with public AST-view/destroy
  invariants, normal/ASan smoke coverage, and a scheduled larger ASan campaign.
- Add pinned offline release verification and an evidence-based release guide.
- Establish the repository contract, development roadmap, compatibility policy,
  security policy, and cross-platform Odin CI skeleton.
- Add a source-positioned Unicode-aware SPARQL lexer: global Unicode escape
  preprocessing with raw-source diagnostics, strings, language/datatype
  suffixes, numeric forms, variables, prefixed names, blank labels, comments,
  punctuation, operators, and stable lexical diagnostics.
- Add an internal owned query AST/parser slice for prologue declarations,
  dataset clauses, all four query forms, basic graph patterns, property lists,
  language/datatype literals, source spans, recursive `OPTIONAL`/`UNION`/
  `MINUS`/`GRAPH` patterns, expression-backed `FILTER`/`BIND`, and `VALUES`.
  This is not yet a supported public parser API or a SPARQL conformance claim.
- Add syntax AST support for `ORDER BY`, `LIMIT`, and `OFFSET`.
- Preserve blank property lists and RDF collections as source AST nodes for
  later algebra lowering, rather than generating query variables in the
  parser.
- Fix case-insensitive keyword comparison so lower-case boolean terminals are
  parsed correctly.
- Add source AST support for property paths, subqueries, grouping, aggregates,
  solution modifiers, `SERVICE` syntax, and trailing `VALUES` clauses.
- Add whole-query syntax validation for aggregate arity, projection aliases,
  grouping restrictions, direct subquery placement, and group-local `BIND`
  scope.
- Add a reproducible W3C SPARQL 1.1 Query syntax gate. The pinned manifest
  passes all 63 positive and 31 negative entries; this is syntax coverage only,
  not query-evaluation conformance.
- Expose a pre-1.0, read-only parser API with owned-query lifetime rules,
  diagnostics, and complete source-AST traversal views that keep internal
  arenas private.
- Add a sealed, in-memory RDF dataset with owned-term copying, RDF set
  semantics, default-graph quad-pattern scans, and callback cancellation as
  the substrate for M2 evaluation.
- Add experimental Algebra translation and a bounded default-graph BGP engine
  for `SELECT`/`ASK`, including BASE/PREFIX resolution, RDF literal conversion,
  variable joins, projection, multiset preservation, ASK short-circuiting, and
  explicit solution limits.
- Add an offline W3C Basic BGP evaluation gate with Turtle fixture loading and
  unordered SRX multiset comparison.
- Extend the Basic W3C gate to all 27 pinned manifest entries after RDF
  collection lowering, including empty, single-item, variable-item, and
  two-item query lists.
- Extend the experimental algebra and execution core to an owned recursive
  relation tree with shared multiset join semantics for `OPTIONAL`, `UNION`,
  `MINUS`, graph-scoped BGPs, `VALUES`, `FILTER`, and `BIND`.
- Add explicit default, exact-named, and any-named Dataset scan modes; support
  `FROM` / `FROM NAMED` as a no-network restriction and merge view over named
  graphs already supplied by the application.
- Add the M3 expression kernel for terms, boolean negation, RDF-term equality
  and inequality, plus explicit unbound/error handling in `FILTER` and `BIND`.
- Add an offline W3C SPARQL 1.1 `bindings` gate covering `values01`–`values08`
  with Turtle fixture loading and unordered SRX multiset comparison.
- Add an offline M3 graph-pattern gate covering selected OPTIONAL/UNION and
  MINUS entries, a named-dataset GRAPH-variable entry, and standard RDF/Turtle
  SPARQL result-set decoding.
- Expand that gate with a nested OPTIONAL/UNION case and six additional W3C
  BIND evaluation entries covering arithmetic, joins, filtering, and UNION.
- Apply group-scope FILTER lowering after sibling bindings, with a regression
  test and the W3C `bind08` case for a FILTER that refers to a later BIND.
- Bind GRAPH variables after evaluating their graph-local pattern, fixing their
  scope through nested OPTIONAL and adding three W3C GRAPH evaluation cases.
- Add mixed default/named graph fixture loading and gate sixteen W3C GRAPH
  entries, including graph existence for an empty explicit GRAPH pattern.
- Add the two remaining parseable complex OPTIONAL fixtures to the W3C gate;
  record the third fixture's pinned RDF-reader compatibility exclusion.
- Expand the W3C negation gate with correlated set and temporal exclusions,
  nested MINUS, and named-graph MINUS disjointness.
- Add lexical relational comparison for xsd:string values and complete the
  pinned W3C SPARQL 1.1 negation manifest gate.
- Expand the W3C subquery gate with aggregate, LIMIT, CONSTRUCT, and
  outer-binding-isolation fixtures; record the RDF/XML relative-IRI fixture
  exclusion separately.
- Add a complete W3C SPARQL 1.0 ASK evaluation gate covering boolean results,
  variable bindings, and FILTER.
- Add a complete W3C SPARQL 1.0 type-promotion gate, including XML Schema
  integer-derived numeric types and negative promotion cases.
- Correct open-world value equality for identical invalid/unsupported literals,
  unknown datatype boundaries, and language-string comparisons; add a
  fourteen-case pinned W3C `open-world` regression gate.
- Add validated `xsd:date` equality and relation support, including timezone
  absence semantics and all four W3C open-world date vectors; the pinned
  open-world regression gate now contains eighteen cases.
- Add validated `xsd:dateTime` `<`, `<=`, `>`, and `>=` evaluation with
  explicit-timezone normalization, and promote all four official relation
  vectors into the M4 comparison gate.
- Add `xsd:dateTime` value equality and inequality, including equivalent
  timezone offsets, fractional-second zeroes, and `24:00:00` normalization;
  promote the official `eq-dateTime` vector into the M4 equality gate.
- Add the validated `xsd:dateTime(...)` scalar cast and promote `cast-dT` into
  the complete seven-case W3C scalar-cast gate.
- Add query-stable `NOW()` with an injectable `engine.Options.Now_Lexical`
  clock and an approved W3C SPARQL 1.1 regression gate.
- Add `UUID()` and `STRUUID()` with a cryptographically secure v4 default,
  a deterministic execution callback, query-local freshness enforcement, and
  three W3C SPARQL 1.1 regression vectors.
- Add `RAND()` with a validated injectable unit-interval source and an
  approved W3C SPARQL 1.1 regression gate.
- Add eight W3C-gated temporal extractors: `YEAR`, `MONTH`, `DAY`, `HOURS`,
  `MINUTES`, `SECONDS`, `TIMEZONE`, and `TZ`.
- Add W3C-gated `REPLACE` with global substitutions, capture-group expansion,
  replacement escaping, language-tag preservation, and SPARQL regex flags.
- Add value-aware `ORDER BY` comparison for validated `xsd:date` and
  `xsd:dateTime` terms, including explicit-offset normalization.
- Add `xsd:time` equality, relation, and `ORDER BY` support with
  explicit-offset normalization.
- Correlate top-level OPTIONAL right-side evaluation with its left mapping,
  preserving explicit merge semantics across filters, subqueries, and SERVICE
  boundaries.
- Add `REGEX` evaluation with SPARQL newline and multiline semantics, plus a
  seventeen-case W3C regex gate and explicit Turtle-result fixture exclusions.
- Add the complete W3C SPARQL 1.0 BOUND-manifest gate.
- Add the complete W3C blank-node coreference gate with source-label-neutral
  result comparison.
- Add the complete W3C effective-boolean-value manifest gate.
- Extend that gate with eight W3C Dataset-manifest entries covering `FROM`,
  `FROM NAMED`, default-graph merge, and named graph restrictions.
- Accept the SPARQL grammar's optional period after non-triple group-pattern
  items (`OPTIONAL`, `FILTER`, `BIND`, `VALUES`, `GRAPH`, nested groups,
  unions, and subqueries).
- Begin M4 value semantics with exact arbitrary-length `xsd:integer` /
  `xsd:decimal` equality and relations, floating promotion, and pinned W3C
  `expr-equals` and numeric `expr-ops` gates.
- Add error-aware short-circuit `&&` / `||` evaluation and numeric effective
  boolean values, with a pinned OPTIONAL-scoped W3C boolean-expression gate.
- Add numeric unary `+` / `-` evaluation with owned generated-term lifetimes
  and a pinned W3C `expr-ops` unary-expression gate.
- Add bounded arbitrary-precision `xsd:integer` / `xsd:decimal` `+`, `-`, and
  `*`, with `Max_Numeric_Digits`, explicit numeric-limit errors, and a pinned
  W3C exact-arithmetic gate.
- Add integer/decimal division with an explicit decimal precision context,
  exact terminating results, and half-even rounding for recurring values;
  add promoted IEEE 754 float/double arithmetic and pinned mixed-type W3C
  arithmetic gates.
- Add `BOUND` as a dedicated binding-state expression with W3C OPTIONAL/FILTER
  coverage for unbound variables.
- Add `sameTerm` RDF-term equality, distinct from SPARQL value equality, plus
  blank-node-aware W3C result comparison and a pinned `expr-builtin` gate.
- Add `STR`, `LANG`, and `DATATYPE` built-ins with eleven W3C built-in cases.
- Add `isIRI`/`isURI`, `isBlank`, and `isLiteral` RDF-term kind built-ins;
  fourteen compatible W3C built-in cases now gate the first three, while the
  official `isLiteral` result fixture is tracked as an `odin-rdf` Turtle-reader
  compatibility gap rather than being rewritten in the SPARQL runner.
- Add `langMatches` with case-insensitive basic language-range semantics and
  five pinned W3C built-in cases.
- Add `IN` / `NOT IN` expression evaluation, SRX ASK comparison in the shared
  W3C runner, and a three-case SPARQL 1.1 membership gate.
- Add `isNumeric` and extend the SPARQL 1.1 functions gate with its official
  numeric-literal classification case.
- Add lazy `IF` and `COALESCE` functional forms with explicit ordinary-error
  versus resource-error behavior.
- Evaluate SELECT expression aliases as algebra extensions before projection,
  with an official SPARQL 1.1 `IF` projection test.
- Add `CONCAT` with owned output and language-tag compatibility, plus four
  pinned SPARQL 1.1 function tests.
- Add `STRSTARTS`, `STRENDS`, and `CONTAINS` with language-tag compatibility
  checks and three pinned SPARQL 1.1 function tests.
- Add Unicode-code-point `STRLEN`, covered by both BMP and non-BMP SPARQL 1.1
  function fixtures.
- Add language-tag-preserving `STRBEFORE` and `STRAFTER`, with two pinned
  SPARQL 1.1 function tests.
- Add `STRDT` with language-input and datatype type errors, covered by three
  pinned SPARQL 1.1 function tests.
- Add `STRLANG` with owned nested-expression output and case-insensitive RDF
  language-tag identity, covered by all three official W3C fixtures.
- Add query-scoped `BNODE` generation with solution-local string identity and
  per-call freshness, covered by both official W3C fixtures.
- Add the complete W3C SPARQL 1.1 project-expression manifest gate.
- Apply `OFFSET` and `LIMIT` after SELECT projection when ordering and
  duplicate modifiers are absent; negative or overflowing bounds return an
  explicit `Invalid_Slice` error.
- Add exact `ABS`, `CEIL`, `FLOOR`, and `ROUND` for `xsd:integer` and
  `xsd:decimal`, with pinned SPARQL 1.1 function tests.
- Add UTF-8 byte-precise `ENCODE_FOR_URI`, including non-BMP W3C coverage.
- Add code-point `SUBSTR` with exact decimal index rounding, language-tag
  preservation, and BMP/non-BMP W3C coverage.
- Add `MD5`, `SHA1`, `SHA256`, `SHA384`, and `SHA512` with Unicode test
  vectors; legacy digests are retained only for SPARQL interoperability.
- Add projected-binding `DISTINCT` and spec-permitted full-deduplication
  `REDUCED`; `DISTINCT` is gated by six pinned W3C result sets.
- Add an explicit, stable `ORDER BY` algebra operator with cached expression
  keys before projection, duplicate modifiers, and slicing. Thirteen
  applicable pinned W3C ordering fixtures now gate it; the runner also reads
  historic RDF/XML result sets and ordered Turtle `rs:index` sequences.
- Add exact XSD casts for `xsd:integer`, `xsd:decimal`, `xsd:boolean`, and
  `xsd:string`, gated by four pinned W3C cast fixtures. This also adds the
  cast-based function ordering fixture to the `ORDER BY` gate.
- Add `xsd:float` and `xsd:double` casts, including compatible string and
  boolean inputs plus XSD special floating lexical forms; the W3C cast gate
  now contains six fixtures.
- Add BASE-capturing `IRI` / `URI` evaluation for IRI and runtime string
  arguments, covered by two pinned SPARQL 1.1 function fixtures.
