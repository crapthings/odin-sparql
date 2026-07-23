# Bounded property-path extension gate

These fixtures cover the `{n}`, `{n,m}`, and `{n,}` bounded path extensions
implemented by `odin-sparql`. They are a local, offline compatibility gate:
the pinned SPARQL 1.1 property-path manifest does not contain these forms, so
they are not presented as W3C conformance cases.

All cases use one small graph with a `c → d → c` cycle. `exact-two` proves an
exact two-step path; `finite-one-two` proves inclusive finite-range endpoints;
and `open-two` proves lower-bound closure plus duplicate suppression across the
cycle.
