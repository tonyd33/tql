#!/usr/bin/env bash

set -euo pipefail

compile_flags=(-Doptimize=ReleaseFast --release=fast)

suite=$1
shift

if ! [ -d "cli-tests/$suite" ]; then
  echo suite does not exist >&2
  exit 1
fi

zig build "${compile_flags[@]}" run -- \
  --language typescript \
  --from-file="cli-tests/$suite/query.tql" \
  "cli-tests/$suite/source.ts" \
  "$@"
