#!/usr/bin/env python3
"""Parse a ycsb_test stdout log and the per-epoch .lat files.

Emits one CSV row to stdout:
    workload,threads,coros,nodes,duration_s,total_ops,throughput_mops,p50_us,p95_us,p99_us,p999_us

Throughput is computed as (sum of `cluster throughput X.XXX Mops` across all
benchmark epochs) divided by epoch count. Duration is epoch_count * EPOCH_LEN
where EPOCH_LEN is read from the log if present (default 0.2s for
SHORT_TEST_EPOCH builds).

Latency percentiles are aggregated over every `epoch_*.lat` file in --lat-dir;
each line is `<bucket_us>\t<count>` and bucket size is 0.1us.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from typing import List, Tuple


CLUSTER_TP_RE = re.compile(r"cluster throughput\s+([0-9.]+)\s+Mops")
WARMUP_RE = re.compile(r"warmup time\s+([0-9.]+)s")
EPOCH_RE = re.compile(r"epoch\s+(\d+)\s+passed")


def parse_log(log_path: str) -> Tuple[float, int]:
    """Returns (avg_throughput_mops, n_epochs)."""
    tps: List[float] = []
    n_epochs = 0
    with open(log_path, "r", errors="replace") as f:
        for line in f:
            m = CLUSTER_TP_RE.search(line)
            if m:
                tps.append(float(m.group(1)))
            m2 = EPOCH_RE.search(line)
            if m2:
                n_epochs = max(n_epochs, int(m2.group(1)))
    if not tps:
        return 0.0, n_epochs
    # drop the 1st epoch (warmup of cache+JIT effects)
    if len(tps) >= 3:
        useful = tps[1:]
    else:
        useful = tps
    return sum(useful) / len(useful), n_epochs


def percentile(buckets: List[Tuple[float, int]], pct: float) -> float:
    total = sum(c for _, c in buckets)
    if total == 0:
        return float("nan")
    target = total * pct / 100.0
    cum = 0
    for us, cnt in buckets:
        cum += cnt
        if cum >= target:
            return us
    return buckets[-1][0]


def parse_lat_dir(lat_dir: str) -> List[Tuple[float, int]]:
    """Aggregates all per-epoch latency histograms (drops the very first epoch
    so warmup spikes don't dominate)."""
    files = sorted(glob.glob(os.path.join(lat_dir, "epoch_*.lat")))
    if not files:
        return []
    if len(files) >= 3:
        files = files[1:]  # drop warmup
    bucket_to_count: dict[float, int] = {}
    for fp in files:
        with open(fp, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) != 2:
                    continue
                try:
                    us = float(parts[0])
                    cnt = int(parts[1])
                except ValueError:
                    continue
                if cnt <= 0:
                    continue
                bucket_to_count[us] = bucket_to_count.get(us, 0) + cnt
    return sorted(bucket_to_count.items())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--lat-dir", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--threads", required=True)
    ap.add_argument("--coros", required=True)
    ap.add_argument("--nodes", required=True)
    ap.add_argument("--epoch-len", type=float, default=0.2,
                    help="seconds per epoch (matches SHORT_TEST_EPOCH=0.2)")
    args = ap.parse_args()

    avg_tp, n_epochs = parse_log(args.log)
    duration = n_epochs * args.epoch_len
    total_ops = int(avg_tp * 1e6 * duration) if duration > 0 else 0

    buckets = parse_lat_dir(args.lat_dir)
    p50 = percentile(buckets, 50.0)
    p95 = percentile(buckets, 95.0)
    p99 = percentile(buckets, 99.0)
    p999 = percentile(buckets, 99.9)

    fields = [
        args.workload,
        args.threads,
        args.coros,
        args.nodes,
        f"{duration:.2f}",
        f"{total_ops}",
        f"{avg_tp:.3f}",
        f"{p50:.2f}" if p50 == p50 else "nan",
        f"{p95:.2f}" if p95 == p95 else "nan",
        f"{p99:.2f}" if p99 == p99 else "nan",
        f"{p999:.2f}" if p999 == p999 else "nan",
    ]
    print(",".join(str(x) for x in fields))
    return 0


if __name__ == "__main__":
    sys.exit(main())
