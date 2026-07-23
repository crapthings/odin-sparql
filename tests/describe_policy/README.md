# M6 DESCRIBE policy fixtures

These are library-policy fixtures, not W3C conformance tests: SPARQL leaves
DESCRIBE graph construction implementation-defined. They pin this repository's
concise policy through the public parser, engine, and graph-isomorphism runner.

The cases cover explicit IRI targets, an explicit target surviving an empty
WHERE result, variable targets, `DESCRIBE *` target discovery, and a variable
blank-node target selected from a declared `FROM` graph. The final three cases
fix the local policy for solution modifiers: `ORDER BY`, `OFFSET`, and `LIMIT`
select only variable-derived description targets, while an explicit IRI remains
described independently of the WHERE solution sequence. Two aggregate cases
also fix `GROUP BY`/`HAVING` and aggregate `ORDER BY` behavior before the
variable-derived targets are collected. A final aggregate case verifies that a
query-level `VALUES` clause joins after `HAVING` before targets are collected.
