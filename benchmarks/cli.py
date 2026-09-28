#!/usr/bin/env python3
"""Measure the complete read-only JSON CLI, including report construction/output.

Alternates AB/BA processes, checks the complete JSON contract (excluding only
time/version metadata), and preserves every measured sample and binary hash.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--command", choices=("scan", "quick-wins"), default="quick-wins")
    parser.add_argument("--min-bytes", type=int, default=50_000_000)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--runs", type=int, default=7)
    args = parser.parse_args()
    if args.runs < 1 or args.min_bytes < 0 or not 1 <= args.limit <= 1000:
        parser.error("runs must be positive, min-bytes nonnegative, and limit 1..1000")
    expected = None

    def run(label):
        nonlocal expected
        cmd = ["/usr/bin/time", "-l", str(getattr(args, label).resolve()), args.command,
               "--root", str(args.path.resolve()), "--min-bytes", str(args.min_bytes),
               "--limit", str(args.limit)]
        start = time.perf_counter()
        result = subprocess.run(cmd, capture_output=True, check=True)
        elapsed = time.perf_counter() - start
        value = json.loads(result.stdout)
        scan = value.pop("scan_seconds")
        value.pop("generated_at_unix")
        value.pop("version")
        if expected is None:
            expected = value
        elif value != expected:
            raise RuntimeError("CLI results changed; do not compare timings on this changing tree")
        record = {"build": label, "wall_seconds": elapsed, "scan_seconds": scan,
                  "non_scan_seconds": elapsed - scan, "json_bytes": len(result.stdout)}
        for key, pattern in (
            ("max_rss_bytes", rb"(\d+)\s+maximum resident set size"),
            ("peak_footprint_bytes", rb"(\d+)\s+peak memory footprint"),
        ):
            match = re.search(pattern, result.stderr)
            if match:
                record[key] = int(match[1])
        return record

    for _ in range(2):
        for label in ("baseline", "candidate"):
            run(label)
    rows = []
    for pair in range(args.runs):
        for label in (("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")):
            row = {"pair": pair + 1, **run(label)}
            rows.append(row)
            print(json.dumps(row), flush=True)
    summary = {}
    for label in ("baseline", "candidate"):
        selected = [r for r in rows if r["build"] == label]
        summary[label] = {
            "median_wall_seconds": statistics.median(r["wall_seconds"] for r in selected),
            "wall_range_seconds": [min(r["wall_seconds"] for r in selected), max(r["wall_seconds"] for r in selected)],
            "median_scan_seconds": statistics.median(r["scan_seconds"] for r in selected),
            "median_non_scan_seconds": statistics.median(r["non_scan_seconds"] for r in selected),
            "median_peak_footprint_bytes": statistics.median(r["peak_footprint_bytes"] for r in selected),
        }
    output = {
        "platform": platform.platform(), "cpus": os.cpu_count(),
        "path": str(args.path.resolve()), "command": args.command,
        "min_bytes": args.min_bytes, "limit": args.limit,
        "binary_sha256": {label: hashlib.sha256(getattr(args, label).read_bytes()).hexdigest()
                          for label in ("baseline", "candidate")},
        "all_reports_identical": True, "inventory_summary": expected["summary"],
        "coverage": expected["coverage"], "summary": summary, "measurements": rows,
        "note": "non_scan_seconds includes process startup, path validation, report/JSON, teardown and parent overhead; it is not isolated report CPU time.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
