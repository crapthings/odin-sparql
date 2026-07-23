# Security policy

## Reporting a vulnerability

Do not disclose suspected vulnerabilities in a public issue. Use GitHub's
private vulnerability-reporting flow when available. Otherwise contact the
repository owner privately with the affected release or commit, a minimal
reproduction, impact, and relevant resource-limit settings.

## Scope

This library will process untrusted SPARQL input and caller-supplied RDF data.
Resource exhaustion, parser differentials, unsafe output handling, and
violations of documented ownership or no-network boundaries are in scope.
Applications remain responsible for transport, TLS, redirects,
authentication, caching, allow lists, and deployment policy for callbacks.
