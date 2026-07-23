# Releasing

`odin-sparql` is pre-1.0, but every tag must still be explainable and
repeatable. A release is a compatibility and evidence statement, not merely a
version number. Version numbers are expressed by immutable annotated Git tags;
this repository intentionally has no separate mutable version file.

## Prepare

Before verification, the release owner must:

- confirm the release scope and semantic version;
- update `README.md`, `CHANGELOG.md`, compatibility, security, and API
  documents for every user-visible or compatibility-relevant change;
- review the intended public package surface (`sparql`, `sparql/dataset`,
  `sparql/engine`, and `sparql/results`) against `docs/compatibility.md`;
- record a dated changelog section with migration notes for any incompatible
  pre-1.0 change; and
- run `git diff --check` and inspect the tag candidate so generated or local
  files cannot enter the release.

For a proposed `1.0.0` tag, this review is a deliberate API-freeze decision:
the parser, Dataset, engine, and results contracts must be accepted together.
Passing the existing tests or completing a feature milestone is necessary
evidence, but does not itself silently freeze an API.

## Inputs

Before verification, select and record:

- the intended `odin-sparql` revision and whether the worktree is clean;
- the released `odin-rdf` revision used by the tag (CI currently pins
  `20f339d1977f14a99ed7962f547db27ba22ae512`, `v0.31.0`);
- the Odin compiler version and target platform; and
- the W3C `w3c/rdf-tests` revision
  `d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86` already present on disk.

Do not use a moving `odin-rdf` branch or a newly fetched W3C fixture as release
evidence. A compatibility-tracking job may use those separately, but it cannot
replace the pinned gate.

## Offline verification

Run the aggregate gate from a checkout with the dependency and fixture cache
available:

```sh
ODIN_RDF_COLLECTION=path/to/odin-rdf \
W3C_TEST_ROOT=path/to/w3c-rdf-tests-pinned-revision \
sh scripts/verify-release.sh
```

The script runs strict checks, the public in-memory and custom-View examples,
all repository test packages plus the fixed-seed parser fuzz campaign, focused AddressSanitizer
checks for the evaluator and engine lifetime boundaries, every claimed W3C
subset, and the local DESCRIBE policy gate. It intentionally never invokes the
fixture downloader.
Its successful output is necessary release evidence, not a claim that every
SPARQL 1.1 manifest is supported; consult `docs/conformance.md` for the exact
ledger.

Run the normal and AddressSanitizer CI lanes on the tag candidate as well.
They provide cross-platform and memory-safety evidence that the local release
script cannot replace.

## Performance review

Planning performance is not an automatic pass/fail release criterion. On a
quiet comparable machine, run:

```sh
BENCH_RUNS=3 BENCH_RECORDS=1000 BENCH_ROUNDS=3 sh scripts/run-benchmarks.sh
```

Retain compiler, platform, configuration, per-process best results, and
execution-statistics output. Investigate repeatable regressions rather than
comparing results across unrelated hardware. The benchmark informs future
dataset-adapter/index choices; it does not make one storage strategy part of
the core API.

## Verify

- [ ] Run `scripts/verify-release.sh` using the pinned local inputs.
- [ ] Review tag-candidate normal and AddressSanitizer CI results on Linux,
      macOS, and Windows.
- [ ] Review benchmark evidence when query-planning behavior changed.
- [ ] Update the conformance ledger before claiming a new W3C capability.
- [ ] Retain the exact dependency revision, fixture revision, compiler,
      platform, and verification output with the release evidence.

## Publish

- [ ] Merge the reviewed candidate into `main` and confirm post-merge CI.
- [ ] Create an annotated `vX.Y.Z` tag at that exact `main` commit; never move
      an existing release tag.
- [ ] Publish concise release notes with compatibility and migration notes.
- [ ] Verify the tag, local `HEAD`, `origin/main`, and published release all
      resolve to the same commit.

If a published artifact is wrong, document it and supersede it with a new
patch release rather than rewriting history.
