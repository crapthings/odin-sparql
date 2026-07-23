#!/bin/sh
set -eu

commit=d3e844aaa3e2f2b5250f2d1c988ce58870d6bc86
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$root/.cache/w3c-rdf-tests-$commit"
suite="$cache/sparql/sparql11/syntax-query"

if [ ! -f "$suite/manifest.ttl" ]; then
  archive="$root/.cache/rdf-tests-$commit.tar.gz"
  mkdir -p "$root/.cache"
  curl --fail --location --retry 3 \
    "https://github.com/w3c/rdf-tests/archive/$commit.tar.gz" \
    --output "$archive"
  mkdir -p "$cache"
  tar -xzf "$archive" --strip-components=1 -C "$cache"
fi

printf '%s\n' "$suite"
