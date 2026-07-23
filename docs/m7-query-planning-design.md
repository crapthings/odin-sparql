# M7 query-planning observability

The core must remain independent of any particular storage engine. Therefore
the first planning slice measures observable work and applies only a
deterministic, storage-agnostic BGP order; it does not assume a cardinality
API, an index layout, or a mutable dataset.

## Opt-in order

`engine.Options.Optimize_BGP` is false by default and preserves source order.
When true, each basic graph pattern prefers fixed RDF terms, then variables
shared by more triple patterns; source position breaks ties. The order changes
only the evaluation order inside one BGP. SPARQL query results are multisets,
so it does not alter bindings or multiplicities. Applications requiring a
particular sequence must continue to use `ORDER BY`.

The heuristic is deliberately conservative: it can make a selective fixed
pattern run before a broad source pattern, but it never claims to know a
provider's cardinalities. Dataset adapters can still use their own indexes
when the evaluator dispatches a more constrained `Quad_Pattern`.

## Execution statistics

Pass a caller-owned `engine.Execution_Statistics` through
`engine.Options.Statistics` to accumulate diagnostic counters. The engine does
not reset the value, allowing an application to measure one call or a complete
workload.

| Counter | Meaning |
| --- | --- |
| `Dataset_Scans` | BGP quad-pattern scans dispatched to a Dataset view. |
| `Dataset_Candidates` | Quads delivered by those scans before binding compatibility checks. |
| `BGP_Matches` | Candidate quads compatible with the current solution mapping. |
| `BGP_Solutions` | Complete BGP mappings appended to an evaluation result. |
| `BGP_Reorders` | BGP evaluations whose opt-in order differed from source order. |
| `Service_Calls` | Endpoint callback invocations made by `SERVICE`. |

Counters are observational: they do not change resource limits, callback
lifetimes, ordering semantics, or error handling. They cover the evaluator's
own BGP and SERVICE work rather than an adapter's unreported internal I/O.

## Measurement protocol

[`benchmarks/bgp`](../benchmarks/bgp) contains a selective join workload and
the reproducible process runner is `scripts/run-benchmarks.sh`. It compares
source order to the opt-in order while printing both timings and the counters
above. Use the same host, compiler, configuration, and median-of-process-best
method for comparisons. The benchmark is evidence for deciding on a future
adapter or index; it is not a portable performance claim.
