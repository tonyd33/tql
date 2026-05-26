# https://just.systems
# vim: noexpandtab tabstop=4 shiftwidth=4

set shell := ["bash", "-euo", "pipefail", "-c"]

mod engine 'packages/tql-engine-zig'
mod grammar 'packages/tree-sitter-tql'
mod js 'packages/tql-js'
mod playground 'packages/playground'

default:
	@just --list

install:
	pnpm install --frozen-lockfile

fmt: engine::fmt
	pnpm exec biome check --write .

check:
	pnpm exec biome check .

build: grammar::build engine::build js::build
	cp packages/tql-engine-zig/zig-out/bin/tql.wasm packages/playground/static/tql.wasm
	just playground::build

[parallel]
test: grammar::test engine::test

[parallel]
clean: grammar::clean js::clean playground::clean engine::clean
	rm -rf node_modules
