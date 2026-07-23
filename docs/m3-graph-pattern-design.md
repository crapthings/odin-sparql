# M3 graph-pattern design

M3 grows the M2 default-graph BGP evaluator into a relational core. The goal
is to make the first non-BGP operators correct by construction, without
creating separate binding, compatibility, and ownership rules in every
operator.

## Execution representation

The algebra translator uses an owned operator tree. Its leaves contain resolved
RDF terms and query-local variable IDs; source AST references never cross the
translation boundary. The current M3 operators are:

- `BGP` — a graph-scoped sequence of triple patterns;
- `Join`, `Left_Join`, `Union`, and `Minus`;
- `Filter`, `Extend` (the algebra form of `BIND`), and `Values`;
- `Graph`, whose graph name is either a resolved RDF term or a variable ID.

The executor evaluates every operator to one internal `Relation`: a multiset
of solution mappings over the plan's complete variable table. Each cell has an
explicit bound flag. The relation owns copied RDF term strings, so it may
outlive a dataset scan but is still internal and bounded by the execution
policy.

The public engine result remains a projection of this relation. It must not
become the implementation representation: SELECT's column order and hidden
variables are presentation concerns, while joins need all variables.

## Shared mapping rules

Two mappings are compatible when every variable bound in both has RDF-term
equality. Joining merges compatible mappings and retains duplicates. `UNION`
concatenates its input multisets. `OPTIONAL` is a correlated left join: its
right group is evaluated once per left mapping, so its `FILTER`, `BIND`,
`GRAPH`, or `SERVICE` may read left-side variables; compatible results are
explicitly merged, or exactly the untouched left mapping is emitted when none
survives. `MINUS` removes a left mapping only when a compatible right mapping
shares at least one bound variable; disjoint mappings do not eliminate it.

These rules are implemented once in the Relation layer. BGP candidate scans,
`VALUES`, and graph-variable scans all produce the same mapping shape.

## Graph scope

`dataset.Quad_Pattern` has three explicit scopes:

- `Default` (the zero value) selects only default-graph quads;
- `Named` selects exactly one named graph;
- `Any_Named` selects named graphs only.

`GRAPH <term>` evaluates its child with `Named`. `GRAPH ?g` scans
`Any_Named`, binds `?g` to each matching quad's graph term, and never sees the
default graph. Dataset descriptions (`FROM` / `FROM NAMED`) are handled as a
separate dataset-view transformation, rather than changing these local scan
rules or adding hidden file/network loading to the engine. In the supplied
in-memory adapter, a source IRI denotes an already-present named graph with
that graph name; `FROM` merges its declared source graphs into the active
default graph, while `FROM NAMED` restricts graph-pattern access to the named
source list.

## Expressions and failures

Expression evaluation returns one of `value`, `unbound`, or `error`; neither
unbound nor error is encoded as an RDF term. `FILTER` retains only effective
boolean true. An error or unbound result therefore rejects the solution.
`BIND` extends an unbound target on a value; an unbound/error result leaves the
target unbound. Group-local rebinding is rejected by parser validation. The
current expression kernel supports terms, `!`, RDF-term equality/inequality,
and boolean/string effective values. The broader SPARQL function set,
arithmetic, and modifiers remain M4.

## Limits and test gates

Each relational operation is multiplicative. A materialization limit is
checked before appending every output mapping; SELECT returns an explicit
limit error, while ASK may stop after its first solution. Scan cancellation is
propagated to Dataset views whenever a parent no longer needs candidates.

W3C evaluation tests are added operator by operator, with the exact manifest
entries recorded in `docs/conformance.md`. Passing syntax alone never implies
evaluation support.
