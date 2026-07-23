# Deterministic semantic properties

Property tests complement pinned W3C fixtures. They use fixed generators and
seeds, so a failure is reproducible without a random-number service or a
network dependency.

`bgp_order_test.odin` creates 32 deterministic small RDF datasets and compares
the result multiset of a three-pattern BGP under source order and
`engine.Options.Optimize_BGP`. It matches rows one-to-one, preserving duplicate
cardinality and unbound-state semantics. The test proves only this local
equivalence property; W3C gates remain the source of conformance claims.
