#!/usr/bin/env bash

set -euo pipefail

help() {
  cat <<'EOF'
Run benchmarks and write one JSON record per run.

Usage: run.sh --tql TQL [options] [BENCHMARK...]

  --tql TQL          the tql binary to measure
  --suite SUITE      the suite file (default:
                     packages/tql-engine-zig/benchmarks/default.yaml)
  --cache DIR        where corpora are checked out (default: .benchmark-cache)
  --iterations N     runs per benchmark (default: 1)
  --workers N        tql workers (default: 2)
  --out FILE         append JSON lines here (default: stdout)
  BENCHMARK          benchmarks to run (default: every one in the suite)

A suite is a YAML file listing benchmarks. Each names its query, relative
to the suite file, the grammar it runs under, and its corpus: a repository,
a commit, and paths within it ("." is the whole tree). `limit_s`, the
ceiling on the median summed query time, is optional.
EOF
}

# Check out commit $2 of repository $1 under the cache, once, and print the
# checkout's path.
fetch_corpus() {
  local repo=$1 commit=$2 dest
  dest=$cache/$(basename "$repo" .git)-$commit
  if [ ! -d "$dest" ]; then
    echo "fetching $repo at $commit ..." >&2
    git init -q "$dest"
    git -C "$dest" fetch -q --depth 1 "$repo" "$commit"
    git -C "$dest" checkout -q FETCH_HEAD
  fi
  echo "$dest"
}

# Run benchmark entry $1, as JSON, once and print its record.
run_once() {
  local benchmark=$1 iteration=$2 name query grammar corpus path paths stdout stderr start end code stats
  name=$(jq -r .name <<< "$benchmark")
  query=$(realpath "$(dirname "$suite")/$(jq -r .query <<< "$benchmark")")
  grammar=$(jq -r .grammar <<< "$benchmark")
  corpus=$(fetch_corpus "$(jq -r .repository <<< "$benchmark")" "$(jq -r .commit <<< "$benchmark")")
  paths=()
  for path in $(jq -r '.paths[]' <<< "$benchmark"); do
    paths+=("$corpus/$path")
  done
  stdout=$(mktemp)
  stderr=$(mktemp)

  start=$(date +%s%N)
  code=0
  "$tql" query --workers="$workers" --grammar="$grammar" --format=json -f "$query" "${paths[@]}" \
    > "$stdout" 2> "$stderr" || code=$?
  end=$(date +%s%N)

  stats=$(jq -c .stats "$stdout" 2> /dev/null) || true

  jq -nc \
    --arg name "$name" \
    --arg query "$query" \
    --argjson limit "$(jq .limit_s <<< "$benchmark")" \
    --argjson iteration "$iteration" \
    --argjson wall "$((end - start))" \
    --argjson code "$code" \
    --argjson stats "${stats:-null}" \
    --rawfile err "$stderr" '
    {
      benchmark: $name,
      iteration: $iteration,
      query: $query,
      limit_s: $limit,
      wall_time_ns: $wall,
      exit_code: $code
    }
    + ($stats // {})
    + if $code == 0 and $stats != null then {}
      else {error: (if $err == "" then "no stats in output" else $err[-2000:] end)}
      end'
  rm -f "$stdout" "$stderr"
}

tql=
suite=packages/tql-engine-zig/benchmarks/default.yaml
cache=.benchmark-cache
iterations=1
workers=2
out=/dev/stdout
names=()

while [ "$#" -gt 0 ]; do
  case $1 in
    --tql)        tql=$2;         shift ;;
    --suite)      suite=$2;       shift ;;
    --cache)      cache=$2;       shift ;;
    --iterations) iterations=$2;  shift ;;
    --workers)    workers=$2;     shift ;;
    --out)        out=$2;         shift ;;
    -h|--help)    help;           exit 0 ;;
    -*)           echo "unknown option $1" >&2; exit 2 ;;
    *)            names+=("$1") ;;
  esac
  shift
done

if [ -z "$tql" ]; then
  echo "--tql is required" >&2
  exit 2
fi
tql=$(realpath "$tql")
mkdir -p "$cache"
cache=$(realpath "$cache")

if [ "${#names[@]}" -eq 0 ]; then
  for name in $(yq '.benchmarks[].name' "$suite"); do
    names+=("$name")
  done
fi

for name in "${names[@]}"; do
  benchmark=$(yq -o=json -I=0 ".benchmarks[] | select(.name == \"$name\")" "$suite")
  for i in $(seq "$iterations"); do
    echo "$name iteration $i ..." >&2
    record=$(run_once "$benchmark" "$i")
    error=$(jq -r '.error // empty' <<< "$record")
    if [ -n "$error" ]; then
      printf '  failed:\n%s\n' "$error" >&2
    fi
    printf '%s\n' "$record" >> "$out"
  done
done
