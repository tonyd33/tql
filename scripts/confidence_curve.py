#!/usr/bin/env python3
"""Confidence curve for paired head-vs-base benchmark results.

Reads the per-run JSON emitted by .github/workflows/benchmark.yml and answers
"how confident are we that head is at least X% faster than base?" for a sweep
of X, rather than a single point estimate.

The runs are paired within a machine: each machine measures both sides, so the
machine's own speed cancels in the ratio. The unit of evidence is therefore one
log-ratio per machine, and the sample size is the number of machines -- not the
number of runs. Runs on the same machine are correlated, so pooling them as
independent samples would overstate precision.

Usage:
    confidence_curve.py DIR [-k KEY] [--json]
    confidence_curve.py --example [--json]

DIR is laid out like the workflow's merged artifacts:

    DIR/head/<machine>-<iteration>.json
    DIR/base/<machine>-<iteration>.json

where each file is an object holding timing fields in nanoseconds plus a
"machine" field.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from pathlib import Path

DEFAULT_KEY = "query_time_ns"


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

    def __init__(self, log_ratios: dict[int, float]):
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


def load_records(directory: Path) -> dict[str, list[dict]]:
    """Parse every run record from the artifact layout, once.

    Returns {"head": [...], "base": [...]}; each record is the raw JSON object
    a run emitted, carrying its timing fields and its "machine".
    """
    sides: dict[str, list[dict]] = {}
    for side in ("head", "base"):
        side_dir = directory / side
        if not side_dir.is_dir():
            raise SystemExit(f"missing directory: {side_dir}")
        records = []
        for path in sorted(side_dir.glob("*.json")):
            rec = json.loads(path.read_text())
            if "machine" not in rec:
                raise SystemExit(f"{path}: no 'machine' field")
            records.append(rec)
        if not records:
            raise SystemExit(f"no .json files in {side_dir}")
        sides[side] = records
    return sides


def group(records: dict[str, list[dict]], key: str) -> dict[str, dict[int, list[float]]]:
    """Per-side, per-machine timings for one field."""
    out: dict[str, dict[int, list[float]]] = {}
    for side, recs in records.items():
        per_machine: dict[int, list[float]] = {}
        for rec in recs:
            if key not in rec:
                raise SystemExit(f"record for machine {rec['machine']}: no field {key!r}")
            per_machine.setdefault(int(rec["machine"]), []).append(float(rec[key]))
        out[side] = per_machine
    return out


def paired_ratios(sides: dict[str, dict[int, list[float]]]) -> dict[int, float]:
    """Per-machine log(median(head)/median(base)).

    Only machines that measured both sides contribute: a ratio across two
    different machines would reintroduce the machine-speed factor that the
    pairing exists to cancel.
    """
    shared = sorted(set(sides["head"]) & set(sides["base"]))
    dropped = sorted((set(sides["head"]) | set(sides["base"])) - set(shared))
    if dropped:
        print(
            f"warning: ignoring machine(s) {dropped} that did not measure both sides",
            file=sys.stderr,
        )
    if not shared:
        raise SystemExit("no machine measured both head and base")

    ratios = {}
    for m in shared:
        hm = statistics.median(sides["head"][m])
        bm = statistics.median(sides["base"][m])
        if bm <= 0 or hm <= 0:
            raise SystemExit(f"machine {m}: non-positive median timing")
        ratios[m] = math.log(hm / bm)
    return ratios


GRID = [
    -0.25, -0.20, -0.15, -0.10, -0.05, -0.02,
    0.0, 0.02, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30,
]


FIELDS = ["read_time_ns", "parse_time_ns", "query_time_ns"]


def analyze(records: dict[str, list[dict]], keys: list[str] | None = None) -> dict:
    """Paired statistics per timing field, as plain data.

    Emits numbers only -- percentages as fractions, times in nanoseconds.
    Presentation and threshold policy belong to the caller.
    """
    out: dict = {"grid": GRID, "fields": {}}
    for key in keys or FIELDS:
        sides = group(records, key)
        model = Paired(paired_ratios(sides))
        out["fields"][key] = {
            "machines": model.n,
            "df": model.df,
            "head_median_ns": statistics.median(
                [t for runs in sides["head"].values() for t in runs]
            ),
            "base_median_ns": statistics.median(
                [t for runs in sides["base"].values() for t in runs]
            ),
            # Positive speedup means head is faster.
            "speedup": model.point_estimate,
            "bound_95": model.bound(0.95),
            "bound_99": model.bound(0.99),
            "per_machine_speedup": {
                str(m): 1.0 - math.exp(d) for m, d in model.by_machine.items()
            },
            "curve": [
                {"x": x, "confidence": model.confidence(x)} for x in GRID
            ],
        }
    return out


def bound_phrase(model: Paired, level: float) -> str:
    b = model.bound(level) * 100
    if b >= 0:
        return f"head is at least {b:.1f}% faster"
    return f"head is no more than {-b:.1f}% slower"


def report(model: Paired, key: str) -> None:
    pe = model.point_estimate * 100
    verb = "faster" if pe >= 0 else "slower"
    print(f"metric: {key}")
    print(f"machines: {model.n} (df={model.df})")
    print("per-machine speedup:")
    for m, d in model.by_machine.items():
        print(f"  machine {m}: {(1 - math.exp(d)) * 100:+6.1f}%")
    print(f"\npoint estimate: {abs(pe):.1f}% {verb}")
    for level in (0.95, 0.99):
        print(f"{level:.0%} confident: {bound_phrase(model, level)}")
    print()

    print("  X (head faster by)   confidence true effect >= X")
    for x in GRID:
        c = model.confidence(x) * 100
        bar = "#" * round(c / 2.5)
        print(f"  {x * 100:+6.0f}%              {c:5.1f}%  {bar}")
    print("\nNegative X asks about a regression: confidence at X=-0.05 is the")
    print("confidence head is no more than 5% slower.")


def example_records(machines: int = 4, iterations: int = 3) -> dict[str, list[dict]]:
    """Synthesize run records: head truly 12% faster, machines differ.

    Machine speed varies by ~1.6x across runners and each run carries a few
    percent of independent noise, so the pairing is doing real work here.
    """
    rng = random.Random(1234)
    true_ratio = 0.88
    sides: dict[str, list[dict]] = {"head": [], "base": []}
    for m in range(1, machines + 1):
        machine_speed = rng.uniform(0.85, 1.4)
        for _ in range(iterations):
            for side in ("head", "base"):
                factor = true_ratio if side == "head" else 1.0
                sides[side].append(
                    {
                        "read_time_ns": round(1.0e9 * machine_speed * rng.gauss(1.0, 0.03)),
                        "parse_time_ns": round(5.0e9 * machine_speed * rng.gauss(1.0, 0.03)),
                        "query_time_ns": round(
                            10.0e9 * machine_speed * factor * rng.gauss(1.0, 0.03)
                        ),
                        "machine": m,
                    }
                )
    return sides


def write_records(directory: Path, records: dict[str, list[dict]]) -> None:
    """Write records back out in the artifact layout."""
    counters: dict[tuple[str, int], int] = {}
    for side, recs in records.items():
        (directory / side).mkdir(parents=True, exist_ok=True)
        for rec in recs:
            m = int(rec["machine"])
            i = counters[(side, m)] = counters.get((side, m), 0) + 1
            (directory / side / f"{m}-{i}.json").write_text(json.dumps(rec))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Confidence curve for paired benchmark results.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("directory", nargs="?", type=Path, help="dir with head/ and base/")
    parser.add_argument("-k", "--key", default=DEFAULT_KEY, help=f"field (default {DEFAULT_KEY})")
    parser.add_argument("--example", action="store_true", help="generate and analyze sample data")
    parser.add_argument("--keep-example", type=Path, help="write example data here and keep it")
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit paired statistics as JSON for downstream rendering",
    )
    args = parser.parse_args()

    if args.example:
        records = example_records()
    elif args.directory:
        records = load_records(args.directory)
    else:
        parser.error("give a directory, or --example")

    try:
        if args.json:
            print(json.dumps(analyze(records), indent=2))
            return 0
        model = Paired(paired_ratios(group(records, args.key)))
    except ValueError as err:
        raise SystemExit(str(err))

    report(model, args.key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
