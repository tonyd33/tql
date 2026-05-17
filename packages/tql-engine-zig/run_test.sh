#!/usr/bin/env bash

set -euo pipefail

suite=$1
shift

if ! [ -d "cli-tests/$suite" ]; then
  echo suite does not exist >&2
  exit 1
fi

zig build run -- "cli-tests/$suite/query.tql" "cli-tests/$suite/source.ts" "$@"
