# https://just.systems

mod engine 'packages/tql-engine-zig'
mod grammar 'packages/tree-sitter-tql'

default:
    @just --list

install:
    pnpm install

fmt:
    pnpm exec biome format --write .
    @just engine fmt

check:
    pnpm exec biome check .

build: grammar::build engine::build

test: grammar::test engine::test

clean: grammar::clean engine::clean
