# Architecture

## Package boundary

`odin-sparql` depends on `odin-rdf` for RDF 1.1 terms and quads. `odin-rdf`
does not import this repository. Production packages use Odin's named import
collection (`import rdf "odin-rdf:rdf"`), never a checked-in machine-relative
path. Query syntax, algebra, solution mappings, dataset access, indexing, and
execution policy belong here.

The syntax AST and executable algebra are separate representations. The AST
preserves source-oriented information and spans; algebra owns resolved RDF
terms, variable identities, and query semantics. Neither is an incidental
representation of the other.

## Dataset boundary

The evaluator consumes a read-only dataset view with explicit default, exact
named, and any-named graph scopes plus an execution-time snapshot contract. It
must be able to scan a quad pattern without requiring a particular storage
engine.

`rdf/dataset.Collector` is an owned parser-output collector, not a Dataset: it
preserves input order and duplicates. It may feed a `sparql/dataset` ingestion
adapter, but the adapter must present RDF dataset set semantics to queries.
The first in-memory dataset starts with correct semantics and linear scans;
indexes are a measured optimization, not an initial public requirement. The
engine can expose caller-owned execution statistics and an opt-in,
storage-agnostic BGP order, so adapter and index decisions begin with observed
scan work rather than an assumed cardinality model.

## Evaluation semantics

Solution sequences obey SPARQL multiset semantics. A solution binding has an
explicit unbound state; expression errors are not RDF terms and cannot be
represented by an empty string. Query blank-node labels are existential pattern
variables, not dataset blank nodes.

Operators that require retained state, such as ordering, grouping, and paths,
must publish a resource policy. Every execution API will accept explicit limits
and cancellation. Simple scan-driven operators may stream results; no API may
silently materialize an unbounded result set.

## Ownership and diagnostics

Public parsed queries own the memory necessary to outlive the input string and
must have a matching destroy operation. Errors carry stable codes and source
spans. Error message functions do not allocate.

## Network and extension boundary

The core has no HTTP client. Dataset loaders and `SERVICE` integrations are
application callbacks with application-owned authentication, cache, redirect,
TLS, and allow-list policy. `DESCRIBE` returns only outgoing default-graph
triples for its resolved IRI/blank-node targets; it does not traverse links,
include incoming or named-graph statements, or dereference resources. This is
an explicit library policy, never a portable graph-expansion guarantee.
