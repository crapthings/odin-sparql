# Deterministic parser fuzzing

This standalone harness generates reproducible random byte strings, mutations,
and intact representative SPARQL Query forms. Every input must either produce
an error range inside the input or an owned query whose public traversal API is
recursively valid before destruction: source ranges, group/term/path/expression
references, blank-property lists and collections, VALUES cells, subqueries,
and form-specific query views are all walked through the public API.

The intact seed corpus deliberately spans all public query forms plus dataset
clauses, SERVICE, final VALUES, grouping/HAVING, bounded property paths, and
DESCRIBE modifiers. Mutations therefore start from both shallow grammar tokens
and newer deep AST branches instead of relying only on unconstrained bytes.
The harness first parses and traverses every intact seed, so a random campaign
cannot accidentally skip validation of one of those representative branches.

Run the default local campaign:

```sh
odin run tests/fuzz -o:speed -sanitize:address -collection:odin-rdf=../odin-rdf
```

Use a smaller reproducible campaign while investigating a failure:

```sh
odin run tests/fuzz -define:FUZZ_CASES=1000 -define:FUZZ_MAX_BYTES=256 \
  -define:FUZZ_SEED=5720813349214897713 -collection:odin-rdf=../odin-rdf
```

CI runs a smoke campaign for every change. The scheduled fuzz workflow runs a
larger AddressSanitizer campaign with a recorded seed and accepts manual case
count/seed inputs. Preserve a failing seed and add a focused regression.

This is a reproducible crash-and-ownership gate, not a SPARQL conformance claim
or a promise of coverage-guided fuzzing.
