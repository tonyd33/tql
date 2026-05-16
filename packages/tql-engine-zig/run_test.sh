#!/usr/bin/env bash

set -euo pipefail

suite=$1

zig build run -- tests/$suite/query.tql tests/$suite/source.ts
