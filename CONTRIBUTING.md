# Contributing

Changes to syntax or evaluation behavior must include focused positive and
negative tests, a reference to the relevant SPARQL 1.1 grammar production or
specification section, and the applicable pinned W3C gate.

Public APIs must document ownership, allocator behavior, resource limits,
cancellation, and error outcomes. Do not add implicit network I/O or make a
storage engine a required dependency of the core evaluator.

Run strict package checks and affected tests before opening a pull request.
Performance claims require reproducible input, compiler options, and results
from at least three runs.

For BGP ordering work, use `./scripts/run-benchmarks.sh` and retain the
execution-statistics output alongside timing results. Do not treat a synthetic
benchmark as justification for a new mandatory storage dependency.

Before proposing a release, follow [the release guide](docs/releasing.md) and
use `scripts/verify-release.sh` with already-cached pinned W3C fixtures.
