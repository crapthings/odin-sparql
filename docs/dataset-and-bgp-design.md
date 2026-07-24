# Dataset and basic graph-pattern design

## M2 boundary

M2 evaluates `SELECT` and `ASK` basic graph patterns against the default graph
of a read-only RDF dataset. It does not implement `FROM`, property paths,
blank-property/collection lowering, expressions, or solution modifiers; those
remain later algebra slices. M3 adds graph-scoped dataset scans, but `GRAPH`
algebra and dataset-description semantics are still implemented above this
interface.

## Dataset view

`dataset.View` is a borrowed, pull-initiated callback interface. The evaluator
selects one quad pattern and supplies a sink. A `false` sink result stops that
scan successfully; an explicit scan error belongs to the provider. This model
lets a file-backed or remote application adapter stream candidates without
materializing the full graph, while allowing BGP evaluation to stop on limits
or ASK's first solution.

`Quad_Pattern` has optional subject/predicate/object terms and an explicit
graph mode. Its zero value, `Default`, selects only default-graph quads;
`Named` selects one exact graph term; `Any_Named` selects all named graphs.
There is deliberately no ambiguous "any graph" mode: `GRAPH ?g` must not
silently include the default graph.

A view represents one immutable snapshot for a call to evaluation. Application
adapters own synchronization. `Memory_Dataset` enforces this explicitly: it
accepts copied quads only before `seal`, then exposes a read-only view.

`dataset.scan` distinguishes adapter misuse from Dataset lifecycle: a zero
`View` (or a custom view with no scan callback) returns `Invalid_View`, and a
nil sink returns `Invalid_Sink`. `Sealed` is reserved for an unsealed
`Memory_Dataset` being viewed, mutated, or scanned. This lets applications
diagnose an incorrectly wired external adapter without treating it as a normal
snapshot-state outcome.

## RDF set semantics and ownership

`Memory_Dataset` owns cloned RDF term strings through its shared Graph storage
and deduplicates equal default or named quads on insertion. It is intentionally
unlike `odin-rdf`'s parser collector, which preserves source order and
duplicate records. The graph mode is applied at scan time, so retained named
quads participate only in explicit named-graph scans.

Terms and quads emitted by a view borrow from the Dataset; a scan sink must not
retain them after the Dataset is destroyed. A Dataset never owns terms supplied
by external views.

`dataset.add_collector` is the explicit copy boundary for an
`odin-rdf:rdf/dataset.Collector`: it imports the collector's currently retained
quads into an unsealed `Memory_Dataset`, applies RDF dataset set semantics, and
clones every term. The resulting dataset may therefore outlive the collector.
Like individual `add` calls, an allocation failure can leave an already-copied
prefix; applications requiring atomic ingestion should populate a fresh
dataset and discard it on error.

## Algebra and result direction

The first algebra translator will resolve source terms against BASE/PREFIX
declarations into `odin-rdf` values and assign integer identities to query
variables. It produces an internal BGP of term-or-variable slots. The BGP
evaluator extends solution mappings one triple at a time, preserving duplicate
solutions even though the dataset itself is a set.

Materialized result bindings are bounded by an explicit execution limit. This
is deliberately separate from dataset scan cancellation: a provider may
stream indefinitely, but the evaluator must stop once a caller's resource
policy is reached.

The current `sparql/engine` slice translates and evaluates default-graph BGPs
for `SELECT` and `ASK`. SELECT preserves duplicate solutions and reports an
explicit limit error rather than returning an unmarked truncated result. ASK
uses the same limit acknowledgement but stops successfully at its first match.
