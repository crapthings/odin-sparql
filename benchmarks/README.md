# Query-planning benchmarks

The BGP planning benchmark compares source-order evaluation with the optional,
constraint-only `engine.Options.Optimize_BGP` order. Its source query begins
with a broad `knows` pattern; only one joined friend has the fixed `kind`
value. This makes the difference in repeated dataset scans visible without
depending on a storage-specific index.

The measured region includes `engine.execute` and excludes dataset generation
and query parsing. Each round prints execution time plus `Dataset_Scans`,
`Dataset_Candidates`, and `BGP_Reorders`. Those counts explain the workload;
they are not portable throughput or memory claims.

The benchmark passes an explicit `Max_Solutions`, a 32-digit exact-numeric
limit, and a fixed `NOW()` value to every execution. The workload does not
call `NOW()`, but fixing the complete execution context keeps the process
independent of host-clock formatting and reflects the public resource-policy
contract.

Run the reproducible process protocol with:

```sh
BENCH_RUNS=3 BENCH_RECORDS=1000 BENCH_ROUNDS=3 ./scripts/run-benchmarks.sh
```

For a smoke run:

```sh
BENCH_RUNS=1 BENCH_RECORDS=100 BENCH_ROUNDS=1 ./scripts/run-benchmarks.sh
```

Compare the median of each process's best round only on the same machine,
compiler, and configuration. `Memory_Dataset` freezes its owned Dataset set at
seal time; its scans preserve insertion order. The benchmark keeps the
engine's BGP ordering policy explicit.
