# Storage convergence baseline

This is a development baseline, not a public compatibility promise or release
claim. Before a public release, storage convergence follows this order:

1. Keep SPARQL behavior grounded in the pinned W3C conformance gates recorded
   in [conformance.md](conformance.md).
2. Keep RDFS Core and OWL RL behavior grounded in the Reasoner's documented
   W3C vectors and rule-profile ledgers.
3. Change storage ownership only when it preserves those observable semantics.

## Dataset agreement already checked

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

This means the two implementations agree at the SPARQL Dataset boundary for
the covered cases. It does **not** make them the same implementation yet.

## Deliberately not merged yet

`Memory_Dataset` and `odin-graph` still retain their own copied quad storage.
The graph kernel also has a distinct-term bound, while the current SPARQL
Dataset contract does not expose one. More importantly, the Reasoner Store is
not a simple Dataset: it owns term IDs, fact provenance, scan indexes, and a
transactional materialization working copy. Its supported reasoning profiles
are default-graph only.

Replacing the Reasoner Store with the current linear Graph would discard those
properties. Replacing `Memory_Dataset` directly would also make graph storage
mandatory for every SPARQL consumer before its complete contract is proven.

## Next convergence condition

The next implementation change must be backed by a test that compares the
candidate shared representation with both:

1. the complete affected SPARQL W3C query gate; and
2. the applicable RDFS Core or OWL RL Reasoner conformance gate, including
   configured-limit rollback and provenance/index behavior where relevant.

Until then, `sparql/graph_dataset` is the executable comparison surface, not a
replacement claim.
