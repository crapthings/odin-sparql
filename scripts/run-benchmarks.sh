#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
odin_rdf=${ODIN_RDF_COLLECTION:-"$root/../odin-rdf"}
odin_graph=${ODIN_GRAPH_COLLECTION:-"$root/../odin-graph"}
runs=${BENCH_RUNS:-3}
records=${BENCH_RECORDS:-1000}
rounds=${BENCH_ROUNDS:-3}

case $runs:$records:$rounds in
  *[!0-9:]*|0:*|*:0:*|*:0) printf '%s\n' 'BENCH_RUNS, BENCH_RECORDS, and BENCH_ROUNDS must be positive integers' >&2; exit 2 ;;
esac

odin version
uname -sm
revision=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || printf '%s' unknown)
if [ "$revision" != unknown ] && [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
  revision=$revision-dirty
fi
printf 'revision: %s\n' "$revision"
printf 'configuration: runs=%s records=%s rounds=%s optimization=speed\n' "$runs" "$records" "$rounds"

run=1
while [ "$run" -le "$runs" ]; do
  printf '\nBGP planning process %s/%s\n' "$run" "$runs"
  odin run "$root/benchmarks/bgp" -o:speed -define:BENCH_RECORDS="$records" -define:BENCH_ROUNDS="$rounds" -collection:odin-rdf="$odin_rdf" -collection:odin-graph="$odin_graph"
  run=$((run + 1))
done
