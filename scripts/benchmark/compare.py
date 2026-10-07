#!/usr/bin/env python3
"""Compare head and base benchmark results.

Reads the JSON lines `run.sh` writes and answers, per benchmark, "how
confident are we that head is at least X% faster than base?" for a sweep of
X, rather than a single point estimate.

The runs are paired within a machine: each machine measures both sides, so the
machine's own speed cancels in the ratio. The unit of evidence is therefore one
log-ratio per machine, and the sample size is the number of machines -- not the
number of runs. Runs on the same machine are correlated, so pooling them as
independent samples would overstate precision.

Usage:
    compare.py --head DIR --base DIR [--markdown FILE] [--json FILE]
    compare.py --example

Each `*.jsonl` file in DIR holds one machine's runs, and its stem names the
machine: a head file and a base file with the same stem are paired. The
report goes to stdout unless `--markdown` names a file. `--json` writes every
field's comparison in full. The exit status is 1 when a benchmark regressed
past `--regression-pct`, exceeded its `limit_s`, or failed on head.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path


def _betacf(a: float, b: float, x: float) -> float:
    MAXIT, EPS, FPMIN = 300, 3.0e-14, 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < FPMIN:
        d = FPMIN
    d = 1.0 / d
    h = d
    for m in range(1, MAXIT + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < FPMIN:
            d = FPMIN
        c = 1.0 + aa / c
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < FPMIN:
            d = FPMIN
        c = 1.0 + aa / c
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < EPS:
            break
    return h


def _betainc(a: float, b: float, x: float) -> float:
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    front = math.exp(lbeta + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(a, b, x) / a
    return 1.0 - front * _betacf(b, a, 1.0 - x) / b


def t_cdf(t: float, df: int) -> float:
    """P(T <= t) for Student's t with df degrees of freedom."""
    if df <= 0:
        raise ValueError("df must be positive")
    tail = 0.5 * _betainc(df / 2.0, 0.5, df / (df + t * t))
    return 1.0 - tail if t > 0 else tail


# --- Model -----------------------------------------------------------------


class Paired:
    """Per-machine paired log-ratios and the confidence curve they induce.

    A negative mean log-ratio means head is faster than base.
    """

    def __init__(self, log_ratios: dict[str, float]):
        if len(log_ratios) < 2:
            raise ValueError(
                f"need at least 2 machines to estimate spread, got {len(log_ratios)}"
            )
        self.by_machine = dict(sorted(log_ratios.items()))
        d = list(self.by_machine.values())
        self.n = len(d)
        self.df = self.n - 1
        self.mean = statistics.fmean(d)
        self.sd = statistics.stdev(d)
        self.se = self.sd / math.sqrt(self.n)

    @property
    def point_estimate(self) -> float:
        """Speedup fraction; 0.2 means head is 20% faster."""
        return 1.0 - math.exp(self.mean)

    def confidence(self, x: float) -> float:
        """Confidence that head is at least `x` faster (x=0.05 -> 5% faster)."""
        if x >= 1.0:
            return 0.0
        target = math.log1p(-x)
        if self.se == 0.0:
            return 1.0 if self.mean < target else 0.0
        return t_cdf((target - self.mean) / self.se, self.df)

    def bound(self, level: float = 0.95, lo: float = -0.95, hi: float = 0.95) -> float:
        """Largest x such that confidence(x) >= level.

        confidence() is monotonically decreasing in x, so bisect.
        """
        if self.confidence(lo) < level:
            return lo
        for _ in range(200):
            mid = (lo + hi) / 2.0
            if self.confidence(mid) >= level:
                lo = mid
            else:
                hi = mid
        return lo


GRID = [
    -0.25, -0.20, -0.15, -0.10, -0.05, -0.02,
    0.0, 0.02, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30,
]

FIELDS = [
    "read_time_ns",
    "parse_time_ns",
    "query_time_ns",
    "wall_time_ns",
    "peak_rss_bytes",
    "compile_ns",
    "compile_parse_ns",
    "compile_load_ns",
    "compile_prelude_ns",
    "compile_desugar_ns",
    "compile_type_check_ns",
    "compile_simplify_ns",
    "compile_translate_ns",
]

GATED = "query_time_ns"

# Runs keyed by benchmark, then machine.
Runs = dict[str, dict[str, list[dict]]]


def load(directory: Path) -> Runs:
    runs: Runs = {}
    for file in sorted(directory.glob("*.jsonl")):
        for line in file.read_text().splitlines():
            record = json.loads(line)
            compile_times = record.pop("compile", None)
            if compile_times is not None:
                for stage, ns in compile_times.items():
                    record[f"compile_{stage}"] = ns
                record["compile_ns"] = sum(compile_times.values())
            runs.setdefault(record["benchmark"], {}).setdefault(file.stem, []).append(record)
    return runs


def values(machines: dict[str, list[dict]], key: str) -> dict[str, list[float]]:
    """Returns `key` per machine, from the runs that succeeded and reported it."""
    out = {}
    for machine, records in machines.items():
        found = [r[key] for r in records if "error" not in r and key in r]
        if found:
            out[machine] = found
    return out


def median_of(per_machine: dict[str, list[float]]) -> float:
    return statistics.median(v for vs in per_machine.values() for v in vs)


@dataclass
class Comparison:
    head: float
    base: float
    paired: Paired


def compare(head: dict[str, list[dict]], base: dict[str, list[dict]], key: str) -> Comparison | None:
    """Returns the paired comparison of `key`, or None unless two machines measured both sides."""
    h, b = values(head, key), values(base, key)
    shared = sorted(h.keys() & b.keys())
    if len(shared) < 2:
        return None
    ratios = {m: math.log(statistics.median(h[m]) / statistics.median(b[m])) for m in shared}
    return Comparison(median_of(h), median_of(b), Paired(ratios))


def fmt(key: str, value: float) -> str:
    if key == "peak_rss_bytes":
        return f"{value / 2**20:.0f} MiB"
    if key.startswith("compile"):
        return f"{value / 1e6:.1f}ms"
    return f"{value / 1e9:.2f}s"


def pct(x: float) -> str:
    return f"{'+' if x >= 0 else ''}{x * 100:.1f}%"


def bound_phrase(key: str, b: float) -> str:
    better, worse = ("smaller", "larger") if key == "peak_rss_bytes" else ("faster", "slower")
    if b >= 0:
        return f"head is at least {b * 100:.1f}% {better}"
    return f"head is no more than {-b * 100:.1f}% {worse}"


def cells(key: str, head: dict[str, list[dict]], base: dict[str, list[dict]]) -> list[str]:
    """Returns the head, base, delta and 95% bound cells for `key`."""
    c = compare(head, base, key)
    if c is not None:
        # The delta reads opposite to speedup: positive means head is slower.
        return [fmt(key, c.head), fmt(key, c.base), pct(-c.paired.point_estimate),
                bound_phrase(key, c.paired.bound(0.95))]
    h = values(head, key)
    return [fmt(key, median_of(h)) if h else "n/a", "n/a", "not compared", ""]


def problems(name: str, head: dict[str, list[dict]], base: dict[str, list[dict]], regression_pct: float) -> list[str]:
    found = []
    failed = sum("error" in r for records in head.values() for r in records)
    if failed:
        found.append(f"head failed in {failed} run(s)")
    c = compare(head, base, GATED)
    if c is not None and -c.paired.point_estimate * 100 >= regression_pct:
        found.append(f"query time regressed vs base by {-c.paired.point_estimate * 100:.1f}%")
    limit_s = next((r["limit_s"] for records in head.values() for r in records if r.get("limit_s")), None)
    h = values(head, GATED)
    if limit_s is not None and h and median_of(h) >= limit_s * 1e9:
        found.append(f"median query time {median_of(h) / 1e9:.2f}s exceeds {limit_s}s limit")
    return [f"⚠️ **{name}**: {p}" for p in found]


def comparison(head: Runs, base: Runs) -> dict:
    """Returns every field's paired comparison per benchmark head ran, as plain data."""
    out = {}
    for name in sorted(head):
        fields = {}
        for key in FIELDS:
            c = compare(head[name], base.get(name, {}), key)
            fields[key] = None if c is None else {
                "head_median": c.head,
                "base_median": c.base,
                "speedup": c.paired.point_estimate,
                "bound_95": c.paired.bound(0.95),
                "bound_99": c.paired.bound(0.99),
                "per_machine_speedup": {m: 1.0 - math.exp(d) for m, d in c.paired.by_machine.items()},
                "curve": [{"x": x, "confidence": c.paired.confidence(x)} for x in GRID],
            }
        out[name] = fields
    return out


def report(head: Runs, base: Runs, regression_pct: float, base_ref: str | None) -> tuple[str, bool]:
    """Returns the markdown report over the benchmarks head ran, and whether any had a problem."""
    names = sorted(head)
    found = [p for n in names for p in problems(n, head[n], base.get(n, {}), regression_pct)]
    machines = {m for n in names for m in head[n]}
    iterations = max(len(records) for n in names for records in head[n].values())

    lines = ["<!-- benchmark-result -->", *(found or ["✅ **Benchmark passed**"]), ""]
    lines += [
        f"Regression threshold {regression_pct:g}% on query time, per benchmark.",
        f"{len(machines)} machines × {iterations} iterations per side; head and base run on the same machine.",
        "Δ is the paired per-machine estimate, so cross-machine variance cancels.",
    ]
    if base_ref:
        lines.append(f"Base: `{base_ref[:7]}`")
    lines += [
        "",
        "| Benchmark | Query (head) | Query (base) | Δ | 95% confidence "
        "| Compile (head) | Compile (base) | Δ | Peak RSS (head) | Peak RSS (base) | Δ |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for n in names:
        query = cells(GATED, head[n], base.get(n, {}))
        compile_ = cells("compile_ns", head[n], base.get(n, {}))[:3]
        rss = cells("peak_rss_bytes", head[n], base.get(n, {}))[:3]
        lines.append(f"| {n} | " + " | ".join(query + compile_ + rss) + " |")
    return "\n".join(lines) + "\n", bool(found)


def example() -> tuple[Runs, Runs]:
    """Synthesize runs: head truly 12% faster, machines differ.

    Machine speed varies by ~1.6x across runners and each run carries a few
    percent of independent noise, so the pairing is doing real work here.
    """
    rng = random.Random(1234)
    head: Runs = {"synthetic": {}}
    base: Runs = {"synthetic": {}}
    for m in range(1, 5):
        machine_speed = rng.uniform(0.85, 1.4)
        for side, factor in ((head, 0.88), (base, 1.0)):
            side["synthetic"][str(m)] = [
                {
                    "benchmark": "synthetic",
                    "read_time_ns": 1.0e9 * machine_speed * rng.gauss(1.0, 0.03),
                    "parse_time_ns": 5.0e9 * machine_speed * rng.gauss(1.0, 0.03),
                    "query_time_ns": 10.0e9 * machine_speed * factor * rng.gauss(1.0, 0.03),
                    "wall_time_ns": 9.0e9 * machine_speed * rng.gauss(1.0, 0.03),
                    "peak_rss_bytes": 200 * 2**20 * rng.gauss(1.0, 0.01),
                    "compile_ns": 2.0e7 * machine_speed * rng.gauss(1.0, 0.03),
                }
                for _ in range(3)
            ]
    return head, base


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare head and base benchmark results.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--head", type=Path, help="directory of head results")
    parser.add_argument("--base", type=Path, help="directory of base results")
    parser.add_argument("--regression-pct", type=float, default=10.0)
    parser.add_argument("--base-ref", help="commit printed in the report")
    parser.add_argument("--markdown", type=Path, help="write the report here instead of stdout")
    parser.add_argument("--json", type=Path, help="write every field's comparison here")
    parser.add_argument("--example", action="store_true", help="compare synthetic results")
    args = parser.parse_args()

    if args.example:
        head, base = example()
    elif args.head and args.base:
        head, base = load(args.head), load(args.base)
    else:
        parser.error("give --head and --base, or --example")

    text, failed = report(head, base, args.regression_pct, args.base_ref)
    if args.json:
        args.json.write_text(json.dumps(comparison(head, base), indent=2))
    if args.markdown:
        args.markdown.write_text(text)
    else:
        sys.stdout.write(text)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
