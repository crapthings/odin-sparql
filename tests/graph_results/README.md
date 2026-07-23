# Graph result serialization gate

This local, offline gate drives both `CONSTRUCT` and the documented concise
`DESCRIBE` result through the public N-Triples and Turtle writers via the
external basic runner. It compares stable output for IRI, plain-literal,
language-literal, and typed-literal graph terms. It is a serializer
compatibility gate, not a W3C result-format claim.
