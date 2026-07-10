#!/usr/bin/env python3
"""
Backfill a CSV report from an existing run_tests.py JSON report.

Usage:
    python backfill_csv.py path/to/results.json
    python backfill_csv.py path/to/results.json --out path/to/results.csv

If --out is omitted, the CSV is written alongside the JSON file,
using the same stem (e.g. results.json -> results.csv).
"""

import argparse
import csv
import json
import sys
from pathlib import Path

FIELDNAMES = [
    "query", "query_type", "expected_doc", "recall", "precision",
    "first_hit_rank", "reciprocal_rank", "doc_found", "full_recall", "error",
]


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_path", type=Path, help="Path to the existing JSON report")
    parser.add_argument("--out", type=Path, default=None,
                         help="Output CSV path (default: same dir/stem as JSON)")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    if not args.json_path.exists():
        print(f"JSON file not found: {args.json_path}", file=sys.stderr)
        return 1

    report = json.loads(args.json_path.read_text(encoding="utf-8"))
    results = report.get("results", [])

    if not results:
        print("No results found in JSON report — nothing to write.", file=sys.stderr)
        return 1

    csv_path = args.out or args.json_path.with_suffix(".csv")

    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        for r in results:
            reciprocal_rank = r.get("reciprocal_rank")
            writer.writerow({
                "query": r.get("query"),
                "query_type": r.get("query_type"),
                "expected_doc": r.get("expected_doc") or "",
                "recall": r.get("recall"),
                "precision": r.get("precision"),
                "first_hit_rank": r.get("first_hit_rank"),
                "reciprocal_rank": round(reciprocal_rank, 4) if reciprocal_rank is not None else "",
                "doc_found": r.get("doc_found"),
                "full_recall": r.get("full_recall"),
                "error": r.get("error") or "",
            })

    print(f"Wrote CSV summary to {csv_path} ({len(results)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
