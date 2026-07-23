# Public parser API

## Decision

The `sparql` package exposes an owned, read-only source AST. `Query` keeps its
storage layout private: callers obtain information through value views and
opaque arena references. This deliberately separates the long-lived syntax API
from the mutable implementation details that Algebra will need.

`Parse` copies every retained spelling. `Destroy` is required exactly once for
every successful `Parse` result; returned strings, views, references, and a
subquery pointer borrow from that `Query` and become invalid at destruction.
No returned value is independently owned, and no parser API performs I/O.

## Diagnostics

`Parse` returns a zero Query and a `Parse_Error` on failure. The zero Query is
safe to pass to `Destroy`, but it owns no retained input. Use
`Parse_Error_Code` for the stable machine-readable outcome,
`Parse_Error_Range` for its half-open location in the original UTF-8 source,
and `Parse_Error_Message` for the stable allocation-free diagnostic. The range
is meaningful only for a non-`None` code. An AST accessor returning `ok =
false` is different: it reports an invalid reference or index, not a parse
diagnostic.

## Reference model

`Pattern_Ref`, `Expression_Ref`, `Path_Ref`, and `Term_Node_Ref` identify
nodes only within one owning `Query`. They are opaque IDs despite being
integer-backed for ergonomic Odin use. An accessor returning `ok = false`
received an invalid reference or index; this is not a parse error.

Views expose source values, spans, and source-order children. They never expose
the backing dynamic arrays. This gives tooling a complete loss-aware traversal
surface without freezing allocation choices, capacity, or arena layout.

## Query form access

The API exposes prologue and dataset entries, form-specific group-pattern
roots, SELECT projection entries, grouping/HAVING/order expressions, slicing,
and trailing VALUES patterns. `Query_Subquery` returns a borrowed nested query
whose lifetime is bounded by the parent query; callers must not destroy it.

## Source AST access

`Pattern_View` plus pattern accessors cover child groups, BGP triples,
standalone blank-property/collection nodes, GRAPH/SERVICE names, FILTER/BIND
expressions, VALUES rows, and subqueries. `Expression_View`, `Path_View`, and
`Term_Node_View` expose the remaining recursive source constructs. `Path_View`
also exposes bounded-path cardinality through `Minimum`, `Maximum`, and
`Has_Maximum`.

The parser preserves syntactic terms rather than resolving RDF values. Prefix
resolution, decoded RDF terms, generated variables for `[]`/`()` and query
blank labels, and semantic execution remain Algebra responsibilities.

## Stability

The first `0.1.0` API promises these ownership and traversal invariants, not
that every internal node type or indexing strategy remains unchanged. New
syntax fields may gain accessors in later compatible releases. Existing views
and functions will not silently acquire network or evaluation behavior.
