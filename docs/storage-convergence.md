# Shared storage contract

This repository is still in development, so storage follows the specification
and the executable conformance evidence rather than a legacy compatibility
boundary. The ordering is:

1. Keep SPARQL behavior grounded in the pinned W3C conformance gates recorded
   in [conformance.md](conformance.md).
2. Keep RDFS Core and OWL RL behavior grounded in the Reasoner's documented
   W3C vectors and rule-profile ledgers.
3. Change storage ownership only when it preserves those observable semantics.

## Dataset agreement and implementation

`sparql/graph_dataset/graph_dataset_test.odin` runs the same public Dataset
operations through `Memory_Dataset` and the graph-backed Dataset. It proves
agreement for:

- invalid options, quad and lexical-byte admission limits, duplicate no-ops,
  and unchanged cardinality after rejected writes;
- owned lexical values, case-folded language-tag identity, and blank-node
  scope identity;
- sealing, borrowed views, default/named/any-named scans, and successful
  early stop;
- Collector ingestion and a public SPARQL `GRAPH` query over a named graph.

Those comparisons established the observable contract before the implementation
was changed. `Memory_Dataset` now owns one `odin-graph:graph.Graph` directly;
it no longer retains a second quad slice or a second set of copied lexical
strings. Its existing SPARQL API remains the boundary seen by parsers,
evaluators, examples, and W3C runners.

Graph builds immutable subject, predicate, object, graph, and two-term indexes
when `Memory_Dataset.seal` freezes that shared store. Candidate scans preserve
insertion order, so the optimization does not change SPARQL result order.

## Remaining deliberate separation

The SPARQL Dataset deliberately leaves Graph's distinct-term bound unexposed.
More importantly, the Reasoner Store is not merely an RDF Dataset: it owns
term IDs, transactional materialization state, and rule-oriented metadata.
Its supported reasoning profiles are default-graph only.

Replacing the Reasoner Store with Graph today would discard those properties.
The graph reasoner adapter instead provides an explicit frozen closure copy,
including asserted/inferred origin and first derivation supports. That is the
current synchronization point between the two models, not a claim that their
internal identities or transactions are interchangeable.

## Ongoing evidence

Every subsequent storage change must continue to pass:

1. the affected SPARQL W3C query gates; and
2. the applicable RDFS Core or OWL RL Reasoner profile gates, including
   configured-limit rollback and provenance/index behavior where relevant.

`sparql/graph_dataset` remains a focused adapter test surface. It is no longer
the migration target: the main `Memory_Dataset` already uses the same Graph
kernel.
