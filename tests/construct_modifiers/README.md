# CONSTRUCT solution modifier gate

This local, offline gate drives grouped CONSTRUCT queries through the external
runner and graph-isomorphism comparator. It verifies GROUP BY/HAVING,
aggregate ORDER BY/LIMIT, and final `VALUES` after aggregate HAVING are applied
before template instantiation. It is not a W3C manifest claim.
