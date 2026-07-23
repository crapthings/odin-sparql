# Computed DISTINCT aggregate gate

This local offline gate evaluates `COUNT`, `SUM`, and `GROUP_CONCAT` with
`DISTINCT` computed expressions. It ensures their duplicate caches own lexical
values independently from the expression results and aggregate accumulators.
