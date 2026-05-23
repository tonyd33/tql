# Benchmarks

Unorganized benchmarking notes.

Linux source revision used for all benchmarks:
24d479d26b25bce5faea3ddd9fa8f3a6c3129ea7

Query file used for all benchmarks: `benchmarks/linux/query.tql`

## Shell for loop

### Description

Single-threaded shell for loop iteration, one process per file

The worst method. Benchmarking before properly recycling resources during
execution.

Script:

```sh
time for source in ~/code/linux/**/*.c ~/code/linux/**/*.h; do
  echo "processing $source"
  zig-out/bin/tql_engine_zig benchmarks/linux/query.tql "$source" >/dev/null
done
```

Time: >5m. Did not bother letting it complete.

## Find/exec + Multiple Args

### Description

Find/exec to drive file production, CLI takes multiple arguments. Still ends up
with multiple CLI invocations because of max argument length.

Note that results are not completely accurate as there were several segfaults
during execution.

Script:

```sh
time find ~/code/linux \
  -type f \
  -name '*.c' -or -name '*.h' \
  -exec zig-out/bin/tql_engine_zig \
        benchmarks/linux/query.tql {} + > /dev/null
```

Time: 102.90s user 3.02s system 97% cpu 1:48.86 total

## Recursive directory walking + MT

### Description

CLI is powered up with recursive directory walking as well as multithreading.

