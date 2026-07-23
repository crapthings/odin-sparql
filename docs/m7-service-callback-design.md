# M7 SERVICE callback design

`SERVICE` is an explicit application integration point. The engine never
opens a socket, resolves an endpoint, or owns authentication state.

## Callback contract

`engine.Options.Service_Callback` receives a resolved endpoint IRI and the
caller-supplied `Service_Data` pointer. It returns an application-owned
`dataset.View`; the caller keeps all backing state alive for the entire
`engine.execute` call. A false return means that no view is available for that
endpoint.

The SERVICE child algebra runs against the returned view. Its existing input
binding is supplied as a seed, so a variable endpoint and variables already
bound by the left side of a group remain correlated with the remote pattern.
The callback can therefore choose a fixed in-memory view, a local adapter, or
a view backed by its own transport/cache policy. It may be called once per
left-side solution; applications that need reuse should cache at their own
boundary.

## Failure and resource behavior

An ordinary SERVICE without a callback, with an unbound/non-IRI endpoint, or
whose callback declines the endpoint fails with `engine.Service_Error`.
`SERVICE SILENT` turns those endpoint/remote-evaluation failures into the
identity relation and retains the left-side mapping. Memory, numeric, and
solution-limit failures remain visible because SILENT must not bypass explicit
resource limits.

## Scope

The callback only supplies a dataset view. Graph scoping inside the SERVICE
child, including `GRAPH`, follows the same evaluator rules as local execution.
The initial slice deliberately omits SPARQL protocol serialization, HTTP,
redirects, credentials, retries, and endpoint discovery.
