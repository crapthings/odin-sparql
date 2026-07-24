# Dataset API

`sparql/dataset` defines the read-only dataset boundary consumed by
`sparql/engine`. It is not a graph store: it has no transactions, query-driven
loading, indexes, synchronization policy, or network behavior. Applications
either use the bounded in-memory implementation or expose an owned snapshot
through `custom_view`.

The implementation is still evolving, but graph-scope matching, ownership,
lifecycle, early-stop behavior, and error codes are constrained by the SPARQL
W3C gates and the tests in this repository.

## In-memory lifecycle

`Memory_Dataset` presents SPARQL's Dataset API over one owned `odin-graph`
store. Initialize it before use, add quads or a Collector snapshot, seal it,
obtain a borrowed View, then destroy it when no scan or execution still uses
that View. Applications that ingest untrusted or otherwise bounded data can
use `init_with_options` with a distinct-quad limit:

```odin
store: dataset.Memory_Dataset
if dataset.init_with_options(&store, {Max_Quads = 10_000, Max_Lexical_Bytes = 2_000_000}) != .None do return
defer dataset.destroy(&store)

quad := rdf.default_graph_quad(rdf.Triple{
	subject = rdf.iri("urn:ada"),
	predicate = rdf.iri("urn:name"),
	object = rdf.literal("Ada"),
})
if dataset.add(&store, quad) != .None do return
dataset.seal(&store)
view, view_error := dataset.view(&store)
if view_error != .None do return
```

`Memory_Dataset_Options.Max_Quads` and `Max_Lexical_Bytes` must be
non-negative. Zero selects the legacy memory-governed capacity. A positive
`Max_Quads` limits distinct quads; a positive `Max_Lexical_Bytes` limits the
sum of copied `value`, `language`, and `datatype` string bytes across accepted
quad terms. The lexical budget deliberately describes copied string payload,
not allocator or dynamic-array overhead. At either capacity, a new valid quad
returns `Quad_Limit` or `Lexical_Limit` without changing the Dataset, while an
equal quad remains a successful no-op. A negative value makes
`init_with_options` return `Invalid_Options` and leaves a safe-to-destroy zero
Dataset.

`add` validates and copies every term string; callers may immediately reuse or
destroy their input. Equal quads are accepted as no-ops, so `quad_count`
reports RDF Dataset set cardinality across both default and named graphs.
After `seal`, Graph builds immutable scan indexes; `add` and `add_collector`
return `Sealed`, and `seal` itself is idempotent. `view` also returns `Sealed`
before sealing. A View borrows its dataset and becomes invalid when its
`Memory_Dataset` is destroyed.

`add_collector` is the explicit copying ingestion adapter from
`odin-rdf:rdf/dataset.Collector`. It applies the same validation and set
semantics as `add`, and the resulting Dataset can outlive the Collector. It is
intentionally incremental: an allocation failure leaves successfully copied
earlier quads in the Dataset. Use a fresh Dataset and discard it on error when
all-or-nothing ingestion is required. `sink` and `triple_sink` are equivalent
copying callbacks for quad and graph parsers respectively.

## Views and scans

`View` is an opaque, borrowed read-only snapshot. The `scan` function delivers
borrowed quads to a non-nil `Scan_Sink`; the sink must not retain a term beyond
the lifetime guaranteed by the View owner. Returning `false` from a sink is a
successful early stop, not an error. In particular, adapters must not turn it
into a storage failure.

`Quad_Pattern` combines optional subject, predicate, and object constraints
with one graph mode:

| `Graph_Mode` | Required candidates |
| --- | --- |
| `Default` (zero value) | Quads without a graph name. |
| `Named` | Quads in exactly `Graph`. |
| `Any_Named` | Quads in any named graph. |

A false `Has_Subject`, `Has_Predicate`, or `Has_Object` is a wildcard. A true
field requires RDF-term equality. `Graph` is consulted only for `Named`.

## External Dataset adapters

Use `custom_view(scan, data)` to adapt an application-owned index, external
store, or immutable snapshot. `Scan_Proc` is called synchronously with the
adapter's `data`, one `Quad_Pattern`, a sink, and sink data. The adapter must:

- honor every graph mode and term constraint described above;
- keep its backing state and delivered RDF term spellings valid until the scan
  returns;
- avoid mutating the exposed snapshot during a scan or engine execution;
- own synchronization, storage error translation, and any index policy; and
- return its own errors only for actual adapter failures, not sink early-stop.

The runnable [custom View example](../examples/custom_view/main.odin) is the
smallest complete adapter: it implements every graph mode and term constraint,
stops immediately when the engine's sink returns `false`, then executes and
serializes a query through the public API. Replace only its `Source` storage
and `scan` body when adapting a real index or snapshot.

The core neither assumes a storage layout nor materializes an adapter's full
dataset. It does not retain delivered quads after a scan; `engine.Result`
separately copies values it exposes after successful execution.

## Errors

| Code | Meaning |
| --- | --- |
| `None` | The requested operation completed. |
| `Invalid_View` | `scan` received a zero View or one with no scan adapter. |
| `Invalid_Sink` | `scan` received a nil sink. |
| `Invalid_Options` | `init_with_options` received a negative limit. |
| `Invalid_Quad` | `add` received an RDF term arrangement that cannot form a quad. |
| `Sealed` | A mutation, pre-seal View request, or in-memory scan violated the Memory_Dataset lifecycle. |
| `Quad_Limit` | A new distinct quad would exceed the configured `Max_Quads`. |
| `Lexical_Limit` | A new distinct quad would exceed the copied lexical-byte budget. |
| `Out_Of_Memory` | Dataset-owned allocation failed. |

`error_message` returns an allocation-free diagnostic for these stable codes.
The zero `View` is useful only as an invalid sentinel; construct usable Views
with `view` or `custom_view`.
