# SPARQL Results XML gate

This local, offline gate exercises `sparql/results.write_sparql_xml` through
the same external basic runner used by result-format fixtures. It verifies a
SELECT result with IRI, plain, language, and typed literals, plus true and
false ASK documents. XML results have no separate pinned manifest in the W3C
fixture revision used by this repository, so this is a format-compatibility
gate rather than a W3C conformance claim.
