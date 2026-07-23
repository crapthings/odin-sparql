# Compatibility and API stability

`odin-sparql` is pre-1.0. Its stable baseline is SPARQL 1.1 Query. Features are
advertised only after their pinned tests pass.

Patch releases do not intentionally make source-incompatible public API
changes. Minor releases may add APIs or conformance fixes; any unavoidable
pre-1.0 migration is recorded in the changelog.

Documented ownership rules, resource limits, cancellation behavior, stable
error codes, multiset semantics, and no-network boundaries are compatibility
commitments. `main` is an integration branch, not a replacement for a released
version.

## Intended public package surface

The planned stable package surface is deliberately small:

- `sparql`: owned parsing, diagnostics, and read-only source-AST traversal;
- `sparql/dataset`: sealed in-memory datasets and application scan adapters;
- `sparql/engine`: bounded query execution, options, results, and result
  accessors; and
- `sparql/results`: result serialization.

`sparql/algebra`, `sparql/eval`, and `sparql/internal/...` are implementation
packages. Odin can technically import them, but their types, functions, error
codes, and layouts carry no source-compatibility promise. Public packages must
not expose one of those implementation types in a documented stable signature.

The parser, Dataset, execution, and graph-result documents define the
ownership and error contracts that will be frozen for this surface. Any future
public package requires an equally explicit compatibility and ownership policy
before a stable release.
