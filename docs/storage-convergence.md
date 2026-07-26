# Dataset and Graph boundary

`sparql/dataset` is the released, self-contained Dataset boundary. Its
`Memory_Dataset` owns copied RDF values and depends only on `odin-rdf`; it
never imports, pins, or requires `odin-graph`. This keeps a SPARQL release
reproducible without making an experimental Graph checkout part of the public
runtime contract.

The built-in Dataset provides bounded admission, RDF Dataset set semantics,
borrowed sealed views, graph-scoped scans, and deterministic insertion order.
It intentionally does not promise a particular index or storage engine.
Applications that need a specialized index, persistence, synchronization, or
resource policy provide `dataset.custom_view` instead.

## Optional Graph adapter

`sparql/graph_dataset` is an optional adapter package for experiments and
integration tests. It wraps an owned `odin-graph:graph.Graph` in the same
public `dataset.View` contract. It is not imported by `sparql`,
`sparql/dataset`, the public examples, or the offline core release verifier.

Its contract tests compare the Graph-backed adapter with `Memory_Dataset` for
admission limits, deduplication, copied lexical values, blank-node scope,
sealing, graph modes, cancellation, Collector ingestion, and public-engine
execution. Those tests protect adapter compatibility without promoting Graph
to a required SPARQL dependency.

## Release consequence

A post-v0.2 SPARQL release can be qualified with a fixed `odin-rdf` revision
and the pinned W3C fixtures alone. If someone publishes or relies on the
optional Graph adapter, that integration must name its own fixed Graph revision
and validation evidence. It cannot silently become part of the core SPARQL
release just because local development checkouts happen to agree.
