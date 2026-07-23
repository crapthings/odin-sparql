# M6 graph-result design

`sparql/engine` exposes graph results through `Result_Kind.Graph`,
`Triple_Count`, and `Triple`. A graph result owns all returned RDF term
strings, remains valid after the query plan and source dataset are destroyed,
and has RDF graph (set) semantics: duplicate constructed statements appear
once.

## CONSTRUCT

The engine evaluates the WHERE pattern with the normal bounded solution-mapping
evaluator, then instantiates every template triple for every solution.

- An unbound template variable omits that one triple.
- A template blank-node label denotes one blank node within a solution mapping
  and a fresh blank node for every distinct solution mapping.
- Template collections and blank-property lists lower to ordinary RDF triples
  with the same fresh-node rule.
- Invalid RDF triples produced by a variable binding are omitted, as required
  by SPARQL CONSTRUCT template instantiation.

`GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, and `OFFSET` apply to the evaluated
solution sequence before template instantiation. Grouping and ordering use the
same algebra stages as SELECT.
Dataset clauses use the existing application-provided dataset-description
adapter: `FROM` supplies the active default graph, while `FROM NAMED` limits
the named graphs available to GRAPH patterns. The complete pinned CONSTRUCT
manifest's five evaluation fixtures and two shortcut-form negative syntax
fixtures are release-gated; `docs/conformance.md` records their exact scope.

## DESCRIBE

SPARQL leaves DESCRIBE graph construction implementation-defined. This library
implements a concise, no-network policy:

1. Include explicit DESCRIBE IRIs irrespective of WHERE matches; resolve
   variable targets from WHERE solutions, or for `DESCRIBE *` collect their
   IRI/blank-node bindings.
2. In the active default graph, return every triple whose subject is one of
   those resources.
3. Do not traverse objects, include incoming triples, merge named graphs, or
   dereference resources.

This policy is deterministic for a sealed Dataset view and bounded by the
query's `Max_Solutions` plus the application dataset's subject scans. The
`GROUP BY`, `HAVING`, `ORDER BY`, `OFFSET`, and `LIMIT` modifiers are applied
to the WHERE solution sequence before variable-derived (or `DESCRIBE *`)
targets are collected. Explicit IRI targets remain described regardless of
that sequence, including when it is empty or sliced away.

## Serialization

`sparql/results` serializes results without coupling `sparql/engine` to an RDF
syntax. Graph results have N-Triples and Turtle writers, while SELECT and ASK
results have SPARQL Results JSON, XML, CSV, and TSV writers. RDF lexical validation is
delegated to `odin-rdf`, and every writer is atomic on serialization errors.
The bindings writers preserve IRI, blank-node, and literal result kinds;
language literals use `xml:lang`, explicit non-`xsd:string` datatypes are
emitted as datatype metadata, JSON/XML text is escaped by its respective
format writer, CSV cells quote delimiter/control characters, and TSV retains
RDF-term syntax with result-local blank-node labels. The XML writer additionally rejects XML 1.0-forbidden code
points (even when their UTF-8 encoding is otherwise valid), so it never emits
an invalid XML document.

The serializers are an owned-result boundary: the Query and Dataset used to
produce a Result may already be destroyed, but the Result itself must remain
alive for the call. Every writer is atomic, including a result-kind mismatch:
on any non-`None` error the caller's existing `strings.Builder` content is
unchanged.

| Writer | Accepted `engine.Result_Kind` | Error on wrong kind |
| --- | --- | --- |
| `write_sparql_json`, `write_sparql_xml`, `write_sparql_csv`, `write_sparql_tsv` | `Select`, `Ask` | `Not_Bindings_Result` |
| `write_ntriples`, `write_turtle` | `Graph` | `Not_Graph_Result` |

`Invalid_UTF8` and `Invalid_XML_Character` identify binding-result text that
cannot be represented by the requested standard format. `NTriples_Error` and
`Turtle_Error` wrap a graph syntax writer rejection. `results.error_message`
is allocation-free for these stable result-serialization error codes.
