# Query execution API

`sparql/engine` is the bounded in-process execution surface for parsed SPARQL
1.1 Query values. It consumes a borrowed, read-only `dataset.View` and returns
an owned `engine.Result`; it never opens a socket, loads a graph IRI, or
mutates a dataset.

This is the pre-1.0 contract proposed for the stable query API. Changes to its
ownership, limits, error codes, or no-network boundary are compatibility
changes and must be recorded in the changelog.

## Lifecycle

```odin
query, parse_error := sparql.Parse(`SELECT ?name { <urn:ada> <urn:name> ?name }`)
defer sparql.Destroy(&query)
if sparql.Parse_Error_Code(parse_error) != .None do return

view, view_error := dataset.view(&sealed_store)
if view_error != .None do return
result, execute_error := engine.execute(&query, view, {Max_Solutions = 128})
defer engine.destroy(&result)
if execute_error != .None do return

name, bound, ok := engine.Cell(&result, 0, 0)
// `name` borrows from `result`; consume it before destroying `result`.
```

`query` and `view` are borrowed only for `engine.execute`. A successful
`Result` owns all variable names and RDF term strings, so it remains usable
after its query and Dataset are destroyed. Destroy each successful result once
with `engine.destroy`. The zero result is safe to destroy; an error return owns
no result and normally needs no cleanup.

## Resource policy

`Options.Max_Solutions` must be positive. It bounds materialized solution
mappings and is an explicit acknowledgement even for `ASK`. A non-positive
value returns `Invalid_Options`; hitting a positive bound returns
`Solution_Limit`, never a silently truncated result. An invalid non-empty
`Now_Lexical` likewise returns `Invalid_Options` rather than an expression or
dataset failure.

A plain ASK may stop after its first solution. ASK queries with modifiers that
can discard, group, or reorder mappings are evaluated as a bounded solution
sequence before their boolean is decided; they may therefore reach the same
`Solution_Limit` boundary as SELECT.

Exact integer/decimal arithmetic and division require a positive
`Options.Max_Numeric_Digits` when they execute. It limits numeric inputs,
intermediates, and output, returning `Numeric_Limit` on breach.
`Decimal_Division_Precision` controls only non-terminating decimal division;
zero chooses the documented 34-significant-digit default. Query `LIMIT` and
`OFFSET` are separate; invalid machine-integer bounds return `Invalid_Slice`.

`Cancellation_Callback` is optional and receives `Cancellation_Data`. It is
polled before execution, at evaluator/operator boundaries, while BGP and
DESCRIBE scans deliver candidates, inside long-running relation loops (such as
JOIN, DISTINCT, ORDER, GROUP, and property-path traversal), and while public
results are materialized. Aggregate member scans and aggregate `DISTINCT`
deduplication are also polling boundaries.
The first `true` is latched for that `engine.execute` call, so even a one-shot
request observed in a nested operation returns `Cancelled` and no partial
`Result`. It is independent of `Max_Solutions`: a successful scan early-stop
does not mean cancellation. The callback must return promptly. Cancellation
cannot interrupt an application Dataset provider while that provider is still
inside one of its own scan calls; it takes effect at the next polling boundary.
It also takes precedence over `SERVICE SILENT`; silent service failure may
preserve input mappings, but it never converts cancellation into success.

## Result access

| Kind | Accessors | Meaning |
| --- | --- | --- |
| `Select` | `Variable_Count`, `Variable_Name`, `Row_Count`, `Cell` | Ordered projected solutions; `Cell` preserves explicit unbound state. |
| `Ask` | `Ask_Value` | One boolean; row and variable counts are zero. |
| `Graph` | `Triple_Count`, `Triple` | Owned RDF graph with set semantics for CONSTRUCT and documented DESCRIBE. |

`Variable_Name`, `Cell`, `Ask_Value`, and `Triple` return `ok = false` for an
invalid index or incompatible result kind. Returned terms and names borrow from
the `Result` and must not outlive it.

## Result serialization

`sparql/results` serializes a live, owned `engine.Result` without requiring
the originating Query or Dataset to remain alive. `write_sparql_json`,
`write_sparql_xml`, `write_sparql_csv`, and `write_sparql_tsv` handle SELECT
and ASK results; `write_ntriples` and `write_turtle` handle Graph results.
Each writer builds its output atomically: on a serialization error, the caller's
existing `strings.Builder` content is unchanged. The Result itself must remain
alive until the writer returns.

## Errors and integrations

`Invalid_Options` means the caller supplied an invalid execution configuration.
`Algebra_Error` means the parsed query cannot be lowered to supported algebra;
`Unsupported_Query` means a successfully parsed query falls outside the
documented execution policy;
`Evaluation_Error` is an ordinary dataset/evaluator failure; `Service_Error`
means an explicit callback supplied no queryable view; `Cancelled`,
`Solution_Limit`, `Numeric_Limit`, and `Invalid_Slice` are explicit policy
outcomes; and `Out_Of_Memory` reports allocation failure. Expression errors
are not engine errors: FILTER drops their mapping while BIND/projection leaves
its target unbound.

The application keeps the Dataset backing state alive during execution and
supplies synchronization. `FROM`/`FROM NAMED` select only graphs already in
that view. `Service_Callback`, `Cancellation_Callback`, `UUID_Callback`,
`RAND_Callback`, and `Now_Lexical` are the explicit integration and
determinism boundaries. Nil callbacks never trigger implicit network I/O;
UUID/RAND use local cryptographic entropy by default. `Optimize_BGP` is
opt-in, and optional `Execution_Statistics` are caller-owned observational
counters.

The callback types are exported from `sparql/engine` as
`engine.Service_Callback`, `engine.Cancellation_Callback`,
`engine.UUID_Callback`, and `engine.RAND_Callback`; applications do not need
to import `sparql/eval` to configure execution.

## Application Dataset adapters

The full lifecycle, graph matching, ownership, and error contract is in the
[Dataset API](dataset-api.md). In particular, a View is borrowed for the whole
`engine.execute` call and its backing snapshot must remain alive until that
call returns.

Applications integrate an external store, index, or immutable snapshot through
`dataset.custom_view(scan, data)`. `scan` receives one `Quad_Pattern` and must
respect its `Default`, exact `Named`, and `Any_Named` graph modes; it streams
borrowed quads to the supplied sink. A `false` sink return is successful early
termination, not a provider error. The adapter owns its state, synchronization,
and any storage-specific error translation, and must keep emitted terms valid
until the scan call returns. The engine neither materializes the provider's
entire graph nor assumes a particular index or cardinality API. A view without
`scan` is rejected as `Invalid_View`; callers must also supply a non-nil sink
to `dataset.scan` (`Invalid_Sink` otherwise).
