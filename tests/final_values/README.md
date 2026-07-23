# Query-level final VALUES semantics gate

This local, offline gate verifies the SPARQL query-level final `VALUES` clause
is evaluated after grouping and `HAVING`, but before SELECT expressions. The
aggregate case prevents a pre-group `VALUES` join from changing `COUNT` or
filtering out its group; the expression case proves the clause still binds
projection expressions; the ASK case covers the shared non-SELECT algebra
path; the SubSelect case covers its independent grouping and projection
boundary.
