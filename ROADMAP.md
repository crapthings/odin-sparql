# Development roadmap

This roadmap is capability-based: a milestone closes only when its stated
semantic and test gates pass. Dates are deliberately not release criteria.

## Milestone status

| Milestone | Status | Evidence boundary |
| --- | --- | --- |
| M0–M4 | Complete, included in `v0.7.0` | Repository contract, Query parser/BGPs, graph patterns, expressions, and modifiers have their documented strict, sanitizer, and pinned W3C gates. |
| M5 | Complete, included in `v0.7.0` | Subqueries (7 W3C + 5 local final-VALUES cases), grouping/aggregates (38 W3C + 6 syntax + 6 grouping + 2 ownership cases), and property paths (35 W3C + 3 bounded-extension cases) run in offline release verification. |
| M6 | Complete, included in `v0.7.0` | CONSTRUCT, the documented concise DESCRIBE policy, graph ownership, and result serializers have independent offline gates; alternate DESCRIBE policies remain separate scope. |
| M7 | Complete, released in `v0.7.0` | SERVICE callbacks, planning statistics, and the custom-View adapter boundary are implemented; concrete storage adapters remain application-owned by design. |
| M8 | Ongoing hardening | Fuzz/property/sanitizer/benchmark/release evidence is in place; new capability claims must add independent gates. |
| M9 | Deliberate release decision | A 1.0 API freeze requires explicit version and compatibility review; it is not implied by passing gates. |

The table reports implementation readiness, not published tags or full SPARQL
1.1 conformance. Exact W3C claims and exclusions remain in
`docs/conformance.md`.

## M0 — repository contract (complete, no release)

- Establish the SPARQL 1.1 baseline and the `odin-rdf`-only dependency edge.
- Document ownership, no-network, dataset, multiset, error, and resource-limit
  rules before their APIs exist.
- Establish the same baseline quality practices as `odin-rdf`: strict compiler
  checking, tests, sanitizers, cross-platform CI, and pinned W3C fixtures.
- Record the dependency policy: release gates test a pinned `odin-rdf` release;
  a separate compatibility job may track its `main` branch.

## M1 — lexer and query syntax (complete, released in `v0.1.0`)

- Implement a Unicode-aware SPARQL 1.1 lexer with source spans and stable
  diagnostics.
- Implement a public, owned AST for the complete SPARQL 1.1 Query grammar.
- Pin and pass the official SPARQL 1.1 Query positive and negative syntax
  manifests. Update syntax is a later milestone. The pinned Query manifest
  passes 63 positive and 31 negative cases.
- Publish the owned, read-only source-AST traversal contract without exposing
  internal arena layout. See `docs/public-parser-api.md`.
- The complete five-case SPARQL 1.0 I18N manifest separately gates Unicode
  prefixed names, non-ASCII whitespace, and Unicode IRI normalization identity.

## M2 — algebra and basic graph patterns (complete, released in `v0.2.0`)

- Translate AST values to a separate algebra representation with resolved
  names, variable identities, and semantic validation.
- Implement `SELECT` and `ASK` over basic graph patterns.
- Add a set-semantics in-memory dataset and an ingestion adapter from
  `odin-rdf` values. `dataset.add_collector` now imports an owned
  `odin-rdf:rdf/dataset.Collector` snapshot before sealing.
- Gate on relevant W3C basic-query evaluation tests. The complete pinned
  SPARQL 1.0 Basic manifest passes all 27 cases, including the four
  collection-lowering entries verified after M5 lowering landed. The complete
  four-case SPARQL 1.0 Triple Match manifest separately gates repeated
  variables and two-triple shared-variable joins.

## M3 — graph patterns (complete, included in `v0.7.0`)

- Add `FILTER`, `OPTIONAL`, `UNION`, `MINUS`, `GRAPH`, `VALUES`, `BIND`, and
  dataset-description semantics.
- Preserve unbound variables and expression errors distinctly.
- Gate each feature on its relevant W3C evaluation manifest entries. The
  pinned graph-pattern subset passes 50 cases, including the complete
  twelve-entry SPARQL 1.0 Dataset manifest; VALUES is tracked separately in
  its eight-case gate. The complete fourteen-case SPARQL 1.0 Algebra
  manifest separately gates nested OPTIONAL, FILTER scope, and composed
  JOIN/UNION/GRAPH relations.

## M4 — expressions and solution modifiers (complete, included in `v0.7.0`)

- Add SPARQL expression evaluation, built-in functions, `EXISTS`, ordering,
  duplicate handling, and slicing.
- Clocks, random values, and cooperative cancellation are explicit execution
  context. Cancellation is polled at evaluator, scan, and materialization
  boundaries and returns a distinct `Cancelled` outcome.
- Current increment: exact numeric and core scalar functions, projected
  `DISTINCT`/`REDUCED`, bounded `LIMIT`/`OFFSET`, ordered `ORDER BY`, exact
  integer/decimal division, promoted float/double arithmetic, and scalar
  numeric casts are implemented and separately gated. `EXISTS` / `NOT EXISTS`
  now share a seeded correlated-evaluation primitive that retains active named
  graph scope; the complete six-entry SPARQL 1.1 `exists` manifest gates
  default, nested, named-graph, and graph-variable correlation. Validated `xsd:date`
  and relational `xsd:dateTime` comparison are separately gated. `LCASE` and
  `UCASE` use Unicode code-point mappings and preserve language tags, with
  BMP/non-BMP W3C vectors. String search functions enforce compatible language
  tags and are gated with the official preservation/error vectors. Exact
  decimal arithmetic retains operand decimal precision and an integral `.0`
  decimal spelling, and gates the
  `COALESCE` and blank-node-containing numeric-addition result vectors.
  `SUBSTR` accepts exact and finite float/double numeric indexes using the
  same half-toward-positive-infinity rule.
  Grouping and aggregates are delivered in M5; remaining temporal conversion
  value spaces stay separate work.
- The complete thirteen-case SPARQL 1.0 Solution Sequence manifest separately
  gates `ORDER BY` before `LIMIT`, `OFFSET`, and their combined slice behavior.
- A local five-case ASK modifier gate verifies that ordered `OFFSET`/`LIMIT`,
  `GROUP BY`/`HAVING`, and `LIMIT 0` affect the boolean result rather than
  being parsed and ignored. Plain ASK retains its one-solution early stop;
  modifiers that can discard, group, or order mappings use the bounded
  sequence evaluation path.
- The complete two-case SPARQL 1.0 `REDUCED` manifest is gated with its
  specified lax cardinality: emitted mappings form a bounded sub-multiset but
  preserve at least one copy of every distinct expected mapping.
- Query-stable `NOW()` and fresh `UUID()` / `STRUUID()` are implemented with
  explicit clock and UUID-source execution options. `RAND()` has its own
  explicit random-double source. The production UUID and RAND paths use
  cryptographic entropy, and all three features have pinned W3C regression
  gates.
- The initial temporal extraction slice implements `YEAR`, `MONTH`, `DAY`,
  `HOURS`, `MINUTES`, `SECONDS`, `TIMEZONE`, and `TZ` over validated
  `xsd:date`/`xsd:dateTime` values, with an eight-vector W3C gate. Clock and
  timezone extraction also cover `xsd:time` through local boundary tests.
  `xsd:date(...)`, `xsd:dateTime(...)`, and `xsd:time(...)` validate eligible
  string or same-type values and preserve their spelling. Other temporal value
  spaces remain separate work. `ORDER BY` now compares
  validated same-datatype `xsd:date`, `xsd:dateTime`, and `xsd:time` values,
  including explicit-offset normalization, with focused local regression
  coverage.
- `REPLACE` now has a four-vector W3C gate, including capture expansion and
  case-insensitive matching. Its evaluator retains raw regex capture slots so
  an unmatched alternative group expands as SPARQL requires.

## M5 — advanced query operations (complete, included in `v0.7.0`)

- The first subquery slice evaluates `SELECT` subqueries independently and
  applies an explicit projection boundary, including `SELECT *`; it also has
  independent `DISTINCT`/`REDUCED`, `ORDER BY`, and `LIMIT`/`OFFSET` algebra
  stages. Local external gates verify SubSelect's final `VALUES` clause and
  query-level final `VALUES` after `GROUP BY`/`HAVING` but before SELECT
  expressions; pinned W3C fixtures cover nesting and `EXISTS` interaction.
- `GROUP BY`, `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `SAMPLE`, `GROUP_CONCAT`,
  and `HAVING` have a 38-case W3C-gated execution slice, a six-case
  aggregate-scope syntax gate, a two-case computed-`DISTINCT` ownership gate,
  and the complete six-entry SPARQL 1.1
  `grouping` manifest gate. The latter covers group-key aliases, unbound keys,
  expression keys, and invalid ungrouped projection. Aggregate errors leave
  their result binding unbound without dropping the enclosing group.
  Blank-property-list patterns
  lower to private existential variables without leaking them through
  `SELECT *`, including the aggregate fixtures that use `[]`. RDF collections
  lower to `rdf:first`/`rdf:rest`/`rdf:nil` BGPs, including standalone and
  empty collections. A non-variable group key must use `AS ?alias` before it
  can be projected. Property paths retain inverse/sequence BGP lowering where
  possible and otherwise use a dedicated path algebra operator with local
  duplicate suppression: alternatives, negated property sets, and `*`/`+`/`?`
  traversal are supported, including cyclic and named-graph inputs. The
  thirty-five-case W3C gate covers all thirty-three pinned manifest entries,
  plus unlisted bounded `{0}` and `{0,1}` fixtures; this includes
  duplicate-preserving alternative sequences, cyclic diamond traversal,
  named-graph isolation, and empty-graph identity cases.
  `{n}`, `{n,m}`, and `{n,}` compile to a bounded path
  operator; unbounded upper ranges reuse graph closure after their lower bound.
  Nested blank-property-list and collection paths join through that same
  operator without exposing generated existential variables through `SELECT *`.
- A local three-fixture extension gate now independently covers `{n}`, `{n,m}`,
  and `{n,}` over a cyclic graph. It is release-gated but deliberately not a
  W3C conformance claim because the pinned SPARQL 1.1 property-path manifest
  does not contain those forms.

## M6 — graph results (complete, included in `v0.7.0`)

- `CONSTRUCT` instantiates resolved triple templates into an owned RDF graph;
  unbound template variables omit their triples, result statements have graph
  set semantics, and every solution gets a fresh blank-node scope. Collections
  and blank-property lists in explicit templates lower to fresh template nodes.
  A five-case W3C evaluation gate verifies `CONSTRUCT WHERE`, joined
  templates, relative IRI `FROM`, and collection templates with RDF graph
  isomorphism; two CONSTRUCT-specific negative syntax entries also gate the
  BGP-only `CONSTRUCT WHERE` shortcut form. A local three-case graph-isomorphism
  gate separately verifies GROUP BY/HAVING, aggregate ORDER BY/LIMIT, and a
  final `VALUES` clause after aggregate HAVING before template instantiation.
- The complete five-case SPARQL 1.0 CONSTRUCT manifest separately gates graph
  identity, subgraphs, reification with both explicit and blank-property-list
  template blanks, and OPTIONAL template omission.
- `DESCRIBE` now has a concise default-graph policy: resolve requested
  IRI/blank-node targets and return only their outgoing active-default-graph
  statements, without traversal or network access. `sparql/results` writes
  graph results as N-Triples or Turtle and SELECT/ASK results as SPARQL
  Results JSON, XML, CSV, or TSV. A complete four-case SPARQL 1.1 `json-res`
  gate, a complete six-case `csv-tsv-res` gate, and a local three-case XML
  result gate verify JSON serialization structure, `SELECT *` source-column
  order, SELECT term kinds, true/false ASK results, and blank-node
  label-independence. A separate local four-case graph-result gate verifies
  external N-Triples and Turtle serialization of `CONSTRUCT` and `DESCRIBE`
  results with IRI, plain, language, and typed literals. Broader
  CONSTRUCT/DESCRIBE coverage requires a new documented policy and independent
  gate. An eleven-case local DESCRIBE policy gate covers
  the documented implementation-defined graph expansion behavior, including
  `GROUP BY`, `HAVING`, `ORDER BY`, `OFFSET`, and `LIMIT` target selection,
  including final `VALUES` after aggregate HAVING; it is not a W3C claim.

## M7 — external integrations (complete, released in `v0.7.0`)

- Optional `SERVICE` callbacks now map an endpoint IRI to an
  application-owned dataset view, preserving correlated bindings and
  `SERVICE SILENT` failure behavior without implicit network I/O. The complete
  seven-entry SPARQL 1.1 `service` manifest is release-gated by mapping its
  declared `qt:serviceData` endpoint documents to those local callback views.
- Optional execution statistics and a deterministic, constraint-only BGP
  ordering heuristic now establish a measured planning baseline without
  assuming storage cardinalities or indexes. The reproducible benchmark
  reports source-versus-opt-in scan work before an index policy is chosen.
- `dataset.custom_view` is the public external Dataset adapter boundary:
  applications provide a graph-scoped streaming `Scan_Proc` over their own
  snapshot or index, and an external-package regression proves bounded ASK
  early-stop without `Memory_Dataset`. The runnable `examples/custom_view`
  consumer shows the same public contract outside the test package. Add
  storage-specific adapters only when a concrete backend and its ownership/
  error policy are in scope.
- Do not add implicit network behavior.

## M8 — query-engine stabilization (`0.8.0`–`0.9.0`)

- The conformance ledger, deterministic generated-dataset BGP-order multiset
  property gate, parser mutation smoke gate, benchmarks, release guide, and
  pinned offline aggregate verifier are complete. The property and fuzz gates
  run in normal and AddressSanitizer CI; the scheduled ASan fuzz campaign
  records its seed. The CI matrix also runs result serialization tests in both
  lanes.
- Remaining M8 work is to expand the ledger only alongside new, independently
  gated capabilities, preserve cross-platform/sanitizer evidence as the API
  evolves, and decide whether coverage-guided fuzzing offers enough value to
  add beyond the current reproducible campaign.

## M9 — stable query API (`1.0.0`)

- Freeze the documented query API and ownership/resource contracts.
- Publish only the capabilities that pass their pinned W3C gates.
- The pre-freeze audit now names the intended public package surface
  (`sparql`, `sparql/dataset`, `sparql/engine`, and `sparql/results`) and
  documents parser diagnostics, Dataset lifecycle/adapters, execution errors,
  result ownership, and serialization failure behavior. External-package
  regressions cover those ownership and error boundaries. A 1.0 decision still
  requires a deliberate API/version review and the release-guide evidence; it
  is not implied by this preparatory documentation.

## After 1.0

SPARQL Update requires a distinct mutable Graph Store and transaction contract.
HTTP protocol and endpoint work remain separate adapters above the core engine.
