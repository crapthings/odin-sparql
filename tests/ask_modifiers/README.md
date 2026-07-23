# ASK solution modifier gate

This local, offline gate verifies modifiers that can change an ASK boolean:
ordered OFFSET/LIMIT selection, GROUP BY/HAVING, and LIMIT 0. It runs through
the external basic runner and compares standard SPARQL XML boolean results.
It is a local semantic gate, not a W3C manifest claim.
