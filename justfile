# https://just.systems
# vim: noexpandtab tabstop=4 shiftwidth=4

set shell := ["bash", "-euo", "pipefail", "-c"]

mod engine 'packages/tql-engine-zig'
mod grammar 'packages/tree-sitter-tql'
mod playground 'packages/playground'

default:
	@just --list

install:
	pnpm install

fmt:
	pnpm exec biome format --write .
	@just engine fmt

check:
	pnpm exec biome check .

build:
	just grammar::build
	just engine::build -Dwasm=true
	cp packages/tql-engine-zig/zig-out/bin/tql.wasm packages/playground/public/tql.wasm
	just playground::build

test: grammar::test engine::test

clean: grammar::clean engine::clean
