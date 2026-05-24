# https://just.systems
# vim: noexpandtab

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

build: grammar::build engine::build playground::build
	cp packages/tql-engine-zig/zig-out/bin/tql.wasm packages/playground/public/tql.wasm

test: grammar::test engine::test

clean: grammar::clean engine::clean
