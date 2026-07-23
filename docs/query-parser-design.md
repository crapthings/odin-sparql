# SPARQL Query parser design

## Purpose

The parser accepts SPARQL 1.1 Query source and produces an owned, source-
oriented AST. It deliberately does not resolve prefixes, decode RDF lexical
forms, assign variable identifiers, choose a `DESCRIBE` expansion policy, or
evaluate a query. Those are algebra and execution responsibilities.

The grammar and W3C syntax gate are complete. The parser now exposes an owned,
read-only traversal API while remaining pre-1.0; its exact public contract is
recorded in [the public parser API](public-parser-api.md). Internal arena
storage remains hidden so algebra translation can evolve independently.

## Lexer boundary

`sparql/internal/lexer` owns UTF-8 validation, Unicode-aware tokenization,
comments and whitespace, SPARQL's global `UCHAR` preprocessing, longest-token
selection, and raw-source positions. Tokens borrow their spelling from the
scanner's normalized private source. The scanner records a mapping back to raw
input positions, so diagnostics continue to point to the original escape
sequence even though grammar recognition sees the substituted code point.

The parser owns grammar context. For example, the lexer returns `a` as a name;
only a predicate position turns it into `Term_Kind.RDF_Type`. Likewise,
`FROM`, `WHERE`, and expression operators become meaningful only to their
grammar productions.

## AST boundary and ownership

Every source spelling retained by `Query` is cloned into `Query.owned`. A
successful parse therefore outlives the caller's input buffer, and `destroy`
is the sole teardown operation. Parser failure destroys its partially built
query before returning.

The present BGP representation expands `;` and `,` property-list shorthand
into ordinary `Triple_Pattern` values. It intentionally does not expand blank
property lists or RDF collections: those require generated query variables and
must be represented in algebra rather than as an accidental parser side effect.

Blank property lists (`[]`) and RDF collections (`()`) therefore have owned
`Term_Node` entries. A property-list node retains predicate/object lists; a
collection node retains item order. A `Term` refers to its node by index. The
algebra translator, with explicit query scope and fresh-variable allocation,
is the only layer that may lower these nodes into RDF list triples or implicit
join variables. This keeps source spans, syntax inspection, and query blank-
node scoping separate from execution representation.

## Required refactor before graph-pattern features

`OPTIONAL`, `UNION`, `MINUS`, `GRAPH`, `FILTER`, `BIND`, `VALUES`, `SERVICE`,
and subqueries cannot be represented by one flat BGP sequence. The parser now
uses a query-owned pattern-node arena: group nodes retain source-order child
indices, BGP nodes hold triples, and structural operators hold their group
operands. `FILTER` and `BIND` refer to a separate expression-node arena;
`VALUES` preserves variable columns, row order, and explicit `UNDEF` cells.
Algebra will consume this recursive representation directly.
At Query and SubSelect scope the one optional final `VALUES` clause is parsed
after solution modifiers; algebra joins it after grouping and `HAVING`, before
SELECT expressions and ordering.

This ordering keeps the key semantic distinctions intact:

- a group is a join sequence, not an unordered set;
- an OPTIONAL has a left input determined by its preceding group items;
- a UNION has independently scoped group operands;
- `GRAPH` changes active graph while retaining the outer dataset; and
- `FILTER`/`BIND` retain exact source placement and variable scope.

## Dataset clauses

`FROM` and `FROM NAMED` are parsed as syntax data only. Their interaction with
the application dataset, including the empty-default-graph behavior when
`FROM` clauses occur, is specified and validated during algebra translation.
No parser operation reads a graph or opens a URL.

## Delivery gates

1. Finish every SPARQL 1.1 Query lexical terminal and unit-test raw spans.
2. Complete the remaining recursive group patterns, property-list terms,
   collections, paths, `SERVICE`, and subqueries.
3. Parse all query productions, retaining unsupported execution constructs in
   AST rather than rejecting valid source.
4. Pin the official `w3c/rdf-tests` revision; run every Query positive and
   negative syntax manifest offline and record the result in the conformance
   ledger.
5. Expose and stabilize the public parse API for `0.1.0`.
