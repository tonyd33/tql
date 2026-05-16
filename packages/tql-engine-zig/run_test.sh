#!/usr/bin/env bash

set -euo pipefail

suite=$1

if ! [ -d "tests/$suite" ]; then
  echo suite does not exist
  exit 1
fi

zig build run -- "tests/$suite/query.tql" "tests/$suite/source.ts"
