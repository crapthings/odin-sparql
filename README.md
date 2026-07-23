# odin-sparql

An Odin implementation of the SPARQL 1.1 Query Language, built on
[`odin-rdf`](../odin-rdf). It will provide a standards-led query parser,
algebra, and dataset-agnostic execution engine without becoming an RDF store
or opening network connections implicitly.

## Status

Pre-release, with the full SPARQL 1.1 Query syntax manifest gated and a
documented, bounded execution surface. The `sparql/engine` package evaluates
`SELECT`, `ASK`, `CONSTRUCT`, and the documented concise-policy `DESCRIBE`.
Supported graph patterns include BGPs, `OPTIONAL`, `UNION`, `MINUS`, `GRAPH`,
`VALUES`, `FILTER`, `BIND`, subqueries, grouping/aggregates, and property
paths. It also supports solution modifiers and the expression/function slices
recorded in the conformance ledger.

The engine is deliberately dataset-agnostic: use the sealed in-memory Dataset
or an application-owned `dataset.custom_view` adapter. `FROM` / `FROM NAMED`
restrict graphs already exposed by that view and never load resources. Explicit
callbacks provide `SERVICE`, clocks, UUIDs, random values, and cooperative
cancellation without introducing network I/O. Results are owned values and can
be written through `sparql/results` as SPARQL Results JSON/XML/CSV/TSV or graph
N-Triples/Turtle.

Execution is bounded by explicit solution and numeric limits. Exact supported
semantics, W3C coverage, intentional exclusions, and implementation-defined
DESCRIBE behavior are recorded in the conformance and execution API documents;
they are more precise than this overview.

`engine.Options.Optimize_BGP` is an opt-in, deterministic ordering heuristic
for triple patterns inside one basic graph pattern. It is accompanied by
caller-owned `engine.Execution_Statistics` counters, so an application can
measure actual scan work before choosing a dataset adapter or index policy.

SPARQL 1.1 is the normative baseline. SPARQL 1.2 remains out of scope until it
is a stable recommendation and `odin-rdf` has an intentional RDF 1.2 policy.

## Scope

- SPARQL 1.1 query parsing, AST, algebra, and evaluation.
- `SELECT`, `ASK`, `CONSTRUCT`, and documented `DESCRIBE` behavior.
- Dataset adapters, beginning with a bounded in-memory dataset.
- Explicit callback integrations for external graph sources and `SERVICE`.

This repository does not provide a graph store, automatic HTTP access,
authentication, transport, entailment regimes, or a SPARQL protocol endpoint.
SPARQL Update is planned after the query engine is stable.

## Design commitments

- Depend on `odin-rdf`, never the reverse.
- Preserve SPARQL multiset semantics; an RDF dataset is not an ordered,
  duplicate-preserving parser collector.
- State ownership, resource limits, cancellation, and error behavior in every
  public API.
- Pin W3C test-suite revisions and run them without a live-network dependency.
- Keep the core free of implicit network I/O. Loaders and `SERVICE` use
  application-supplied callbacks.

See [the roadmap](ROADMAP.md), [architecture](docs/architecture.md), and
[compatibility policy](docs/compatibility.md). The [conformance policy](docs/conformance.md)
records the rules for future W3C claims. The [query-parser design](docs/query-parser-design.md)
records the syntax/algebra boundary. [The parser API](docs/public-parser-api.md)
defines ownership and read-only AST traversal for the current pre-1.0 surface.
[The query execution API](docs/query-execution-api.md) defines the proposed
stable `engine`/`Result` ownership, resource-limit, and error contracts.
[The Dataset API](docs/dataset-api.md) defines the sealed in-memory lifecycle
and the application-owned scan-adapter contract.
[The M4 expression design](docs/m4-expression-and-modifier-design.md) records
the staged value-semantics and solution-modifier work now underway.
[The M6 graph-result design](docs/m6-graph-results-design.md) defines
CONSTRUCT blank-node and DESCRIBE expansion policy, plus the graph and SPARQL
Results serialization surface.
[The M7 SERVICE callback design](docs/m7-service-callback-design.md) defines
the explicit, no-network federation boundary.
[The M7 query-planning design](docs/m7-query-planning-design.md) documents
the opt-in BGP order, execution statistics, and benchmark protocol.
[The release guide](docs/releasing.md) records the pinned, offline verification
inputs and release evidence required before a tag.
[The compatibility policy](docs/compatibility.md) also names the intended
public package surface, so `algebra`, `eval`, and `internal` imports are not
mistaken for stable extension APIs.

## Dependency setup

The public packages import `odin-rdf` through Odin's named collection support:

```sh
odin test sparql -collection:odin-rdf=path/to/odin-rdf
```

That path may point to a vendored checkout, a sibling directory, or another
application-owned location. Releases pin and test one `odin-rdf` release; see
the architecture document for the compatibility policy.

## Quick start

The [minimal example](examples/minimal/main.odin) is an external-consumer
program: it creates a sealed in-memory dataset, parses and executes a query,
then writes SPARQL Results JSON using only public packages.

The [custom View example](examples/custom_view/main.odin) shows the parallel
path for application-owned storage: it supplies a graph-scoped streaming
`dataset.Scan_Proc` without importing an engine implementation package or
making the core assume an index layout.

```sh
odin run examples/minimal -collection:odin-rdf=path/to/odin-rdf
odin run examples/custom_view -collection:odin-rdf=path/to/odin-rdf
```

It prints:

```json
{"head":{"vars":["name"]},"results":{"bindings":[{"name":{"type":"literal","value":"Ada"}}]}}
```

## Planned layout

```text
sparql/                 Public query parser and execution API
sparql/algebra/         Syntax-to-algebra translation and algebra values
sparql/dataset/         Dataset interfaces and in-memory implementation
sparql/internal/lexer/  SPARQL lexical layer
tests/w3c/              Pinned W3C Query/Update test runners
tests/property/         Deterministic semantic properties
benchmarks/             Reproducible query-planning workloads
examples/minimal/       Public API end-to-end example
examples/custom_view/   Application-owned Dataset adapter example
docs/                   Architecture, conformance, and release policy
```
