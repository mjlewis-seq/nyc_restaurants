#!/usr/bin/env python3
"""
run_tests.py — Retrieval testing harness for a RAGFlow knowledge base.

Runs a set of test queries (test_queries.json) against RAGFlow's retrieval
API (POST /api/v1/retrieval), compares the chunks that come back against the
expected_chunk_ids / expected_doc annotated on each test query, and reports
chunk-level and document-level retrieval quality metrics.

------------------------------------------------------------------------
INPUT FORMAT (test_queries.json) — a JSON list of objects like:

{
  "query": "When is food deemed adulterated?",
  "query_type": "direct",
  "expected_doc": "pdf/health-code-article71.pdf",
  "expected_chunk_ids": ["f8fc28451113a3fd", "ccd0ae05ea83feb4", ...],
  "notes": "optional free-text notes, not used for scoring"
}

Only "query" and "expected_chunk_ids" are required for scoring; "expected_doc"
enables an additional document-level hit check; "query_type" is used purely
to break down metrics by category; "notes" is ignored.

------------------------------------------------------------------------
CONFIGURATION

This script only needs RAGFlow's own API to run retrieval (RAGFlow applies
whatever embedding/rerank models — e.g. Voyage AI — you've already configured
against the dataset internally; you do not need to pass Voyage or Anthropic
keys to this script).

Configuration is read from a .env file (plain KEY=VALUE lines, no extra
dependency required) in the current directory by default, then from the
real environment, then CLI flags — later sources win. Point at a different
file with --env-file if needed. Expected keys in your .env:

    RAGFLOW_BASE_URL     e.g. http://localhost:9380
    RAGFLOW_API_KEY      your RAGFlow API key
    RAGFLOW_DATASET_IDS  comma-separated dataset id(s) to search

Example .env:
    RAGFLOW_BASE_URL=http://localhost:9380
    RAGFLOW_API_KEY=your-ragflow-api-key
    RAGFLOW_DATASET_IDS=b2a62730759d11ef987d0242ac120004

Then simply:
    python run_tests.py --queries test_queries.json --k 10

All generated reports are written under --output-dir (default: ./output),
created automatically if it doesn't exist:

  - output/<run_id>/test_results.json — full detail from that run
  - output/<run_id>/test_results.csv  — optional per-query summary (--csv)
  - output/history.jsonl              — append-only, one row per query per
                                         run (never overwritten), so you can
                                         track a query's metrics across runs
                                         as you expand test_queries.json over
                                         time. Disable with --no-history.

------------------------------------------------------------------------
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import statistics
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import requests


# --------------------------------------------------------------------------
# .env loading (no external dependency — plain KEY=VALUE parser)
# --------------------------------------------------------------------------

def load_dotenv(path: Path) -> None:
    """Load KEY=VALUE pairs from a .env file into os.environ.

    Only sets variables that aren't already present in the real environment,
    so a real `export FOO=bar` always takes precedence over the file. Blank
    lines and lines starting with '#' are ignored. Values may be wrapped in
    single or double quotes; surrounding whitespace is stripped.
    """
    if not path.exists():
        return

    for lineno, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.lower().startswith("export "):
            key = key[len("export "):].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key and key not in os.environ:
            os.environ[key] = value


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

@dataclass
class Config:
    base_url: str
    api_key: str
    dataset_ids: list[str]
    document_ids: list[str]
    queries_path: Path
    output_dir: Path
    output_name: str
    write_csv: bool
    history_enabled: bool
    history_name: str
    run_id: str
    k: int
    top_k: int
    similarity_threshold: float
    vector_weight: float
    rerank_id: Optional[str]
    keyword: bool
    sleep: float
    timeout: float
    verbose: bool

    @property
    def run_dir(self) -> Path:
        # Each run's full-detail JSON/CSV live in their own subfolder, named
        # after the run_id, for tidy organization as runs pile up.
        return self.output_dir / self.run_id

    @property
    def output_path(self) -> Path:
        return self.run_dir / self.output_name

    @property
    def csv_path(self) -> Path:
        return self.run_dir / f"{Path(self.output_name).stem}.csv"

    @property
    def history_path(self) -> Optional[Path]:
        if not self.history_enabled:
            return None
        return self.output_dir / self.history_name


def parse_args(argv: Optional[list[str]] = None) -> Config:
    # Load .env before reading any os.environ defaults below, so a .env file
    # you fill in yourself is picked up automatically. A real exported env
    # var still wins over the .env file (see load_dotenv). A tiny pre-parser
    # picks up --env-file specifically so we know which file to load first.
    pre_parser = argparse.ArgumentParser(add_help=False)
    pre_parser.add_argument("--env-file", default=".env")
    pre_args, _ = pre_parser.parse_known_args(argv)
    load_dotenv(Path(pre_args.env_file))

    parser = argparse.ArgumentParser(
        description="Run retrieval tests against a RAGFlow dataset and score the results.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--queries", default="test_queries.json",
                         help="Path to the test queries JSON file (default: %(default)s)")
    parser.add_argument("--env-file", default=".env",
                         help="Path to a .env file with RAGFLOW_* settings (default: %(default)s)")
    parser.add_argument("--base-url", default=os.environ.get("RAGFLOW_BASE_URL", "http://localhost:9380"),
                         help="RAGFlow base URL (default: .env / env RAGFLOW_BASE_URL, or http://localhost:9380)")
    parser.add_argument("--api-key", default=os.environ.get("RAGFLOW_API_KEY"),
                         help="RAGFlow API key (default: .env / env RAGFLOW_API_KEY)")
    parser.add_argument("--dataset-ids", default=os.environ.get("RAGFLOW_DATASET_IDS", ""),
                         help="Comma-separated RAGFlow dataset ID(s) to search "
                              "(default: .env / env RAGFLOW_DATASET_IDS)")
    parser.add_argument("--document-ids", default=os.environ.get("RAGFLOW_DOCUMENT_IDS", ""),
                         help="Optional comma-separated document ID(s) to restrict the search to")
    parser.add_argument("--output-dir", default="output",
                         help="Directory where all generated reports are written; "
                              "created automatically if missing (default: %(default)s)")
    parser.add_argument("--output-name", default="test_results.json",
                         help="Filename for the detailed JSON report, inside --output-dir (default: %(default)s)")
    parser.add_argument("--csv", action="store_true",
                         help="Also write a per-query CSV summary into --output-dir")
    parser.add_argument("--history-name", default="history.jsonl",
                         help="Append-only JSON-lines log (one row per query per run) inside "
                              "--output-dir, for tracking a query's metrics across runs over time "
                              "(default: %(default)s)")
    parser.add_argument("--no-history", action="store_true",
                         help="Disable writing to the history log")
    parser.add_argument("--k", type=int, default=10,
                         help="Number of chunks to retrieve per query, i.e. page_size (default: %(default)s)")
    parser.add_argument("--top-k", type=int, default=1024,
                         help="RAGFlow 'top_k' — candidate pool size for vector similarity "
                              "computation before ranking (default: %(default)s)")
    parser.add_argument("--similarity-threshold", type=float, default=0.2,
                         help="Minimum similarity score to keep a chunk (default: %(default)s)")
    parser.add_argument("--vector-weight", type=float, default=0.3,
                         help="Weight of vector similarity vs. term similarity, 0-1 (default: %(default)s)")
    parser.add_argument("--rerank-id", default=os.environ.get("RAGFLOW_RERANK_ID") or None,
                         help="RAGFlow rerank model id to use, e.g. 'rerank-2.5-lite@VoyageAI' "
                              "(default: env RAGFLOW_RERANK_ID, or RAGFlow's default if unset)")
    parser.add_argument("--keyword", action="store_true",
                         help="Enable keyword-based matching in addition to vector search")
    parser.add_argument("--sleep", type=float, default=0.2,
                         help="Seconds to sleep between requests, to be polite to the API (default: %(default)s)")
    parser.add_argument("--timeout", type=float, default=30.0,
                         help="Per-request timeout in seconds (default: %(default)s)")
    parser.add_argument("-v", "--verbose", action="store_true",
                         help="Print per-query detail as tests run")

    args = parser.parse_args(argv)

    if not args.api_key:
        parser.error("A RAGFlow API key is required. Set --api-key or the RAGFLOW_API_KEY env var.")

    dataset_ids = [d.strip() for d in args.dataset_ids.split(",") if d.strip()]
    document_ids = [d.strip() for d in args.document_ids.split(",") if d.strip()]

    if not dataset_ids and not document_ids:
        parser.error("At least one dataset ID (--dataset-ids / RAGFLOW_DATASET_IDS) or "
                      "document ID (--document-ids) is required.")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    run_id = uuid.uuid4().hex[:12]
    (output_dir / run_id).mkdir(parents=True, exist_ok=True)

    return Config(
        base_url=args.base_url.rstrip("/"),
        api_key=args.api_key,
        dataset_ids=dataset_ids,
        document_ids=document_ids,
        queries_path=Path(args.queries),
        output_dir=output_dir,
        output_name=args.output_name,
        write_csv=args.csv,
        history_enabled=not args.no_history,
        history_name=args.history_name,
        run_id=run_id,
        k=args.k,
        top_k=args.top_k,
        similarity_threshold=args.similarity_threshold,
        vector_weight=args.vector_weight,
        rerank_id=args.rerank_id,
        keyword=args.keyword,
        sleep=args.sleep,
        timeout=args.timeout,
        verbose=args.verbose,
    )


# --------------------------------------------------------------------------
# Test query loading
# --------------------------------------------------------------------------

@dataclass
class TestQuery:
    query: str
    query_type: str
    expected_doc: Optional[str]
    expected_chunk_ids: list[str]
    notes: str = ""
    raw: dict[str, Any] = field(default_factory=dict)


def load_queries(path: Path) -> list[TestQuery]:
    if not path.exists():
        print(f"error: queries file not found: {path}", file=sys.stderr)
        sys.exit(1)

    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, list):
        print("error: test_queries.json must contain a JSON list of query objects", file=sys.stderr)
        sys.exit(1)

    queries: list[TestQuery] = []
    for i, item in enumerate(data):
        if "query" not in item:
            print(f"warning: skipping entry {i} — missing required 'query' field", file=sys.stderr)
            continue
        queries.append(TestQuery(
            query=item["query"],
            query_type=item.get("query_type", "unspecified"),
            expected_doc=item.get("expected_doc"),
            expected_chunk_ids=list(item.get("expected_chunk_ids", [])),
            notes=item.get("notes", ""),
            raw=item,
        ))
    return queries


# --------------------------------------------------------------------------
# RAGFlow client
# --------------------------------------------------------------------------

class RagflowError(RuntimeError):
    pass


class RagflowClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.session = requests.Session()
        self.session.headers.update({
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg.api_key}",
        })

    def retrieve(self, question: str) -> dict[str, Any]:
        url = f"{self.cfg.base_url}/api/v1/retrieval"
        payload: dict[str, Any] = {
            "question": question,
            "page": 1,
            "page_size": self.cfg.k,
            "top_k": self.cfg.top_k,
            "similarity_threshold": self.cfg.similarity_threshold,
            "vector_similarity_weight": self.cfg.vector_weight,
            "keyword": self.cfg.keyword,
            "highlight": False,
        }
        if self.cfg.dataset_ids:
            payload["dataset_ids"] = self.cfg.dataset_ids
        if self.cfg.document_ids:
            payload["document_ids"] = self.cfg.document_ids
        if self.cfg.rerank_id:
            payload["rerank_id"] = self.cfg.rerank_id

        max_attempts = 4
        backoff = 1.0
        last_err: Optional[Exception] = None

        for attempt in range(1, max_attempts + 1):
            try:
                resp = self.session.post(url, json=payload, timeout=self.cfg.timeout)
            except requests.exceptions.RequestException as exc:
                last_err = exc
                time.sleep(backoff)
                backoff *= 2
                continue

            if resp.status_code == 429 or resp.status_code >= 500:
                last_err = RagflowError(f"HTTP {resp.status_code}: {resp.text[:300]}")
                time.sleep(backoff)
                backoff *= 2
                continue

            try:
                body = resp.json()
            except ValueError as exc:
                raise RagflowError(f"Non-JSON response (HTTP {resp.status_code}): {resp.text[:300]}") from exc

            if body.get("code", 0) != 0:
                raise RagflowError(f"RAGFlow API error {body.get('code')}: {body.get('message')}")

            return body.get("data", {})

        raise RagflowError(f"Retrieval request failed after {max_attempts} attempts: {last_err}")


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------

def normalize_name(name: str) -> str:
    """Lowercase, drop extension/path, strip non-alphanumerics for fuzzy comparison."""
    stem = Path(name).stem.lower()
    return re.sub(r"[^a-z0-9]+", "", stem)


def docs_match(expected_doc: str, actual_name: str) -> bool:
    """Best-effort match between an expected_doc path and a retrieved document name.

    Handles the common case where naming conventions differ (e.g. an
    'article71' style reference vs. an 'H71_...' filename) by falling back to
    shared numeric tokens (article/section numbers), then substring matching.
    Adjust this if your naming convention needs stricter/looser matching.
    """
    e_norm = normalize_name(expected_doc)
    a_norm = normalize_name(actual_name)
    if e_norm == a_norm:
        return True

    e_nums = set(re.findall(r"\d+", expected_doc))
    a_nums = set(re.findall(r"\d+", actual_name))
    if e_nums and a_nums and (e_nums & a_nums):
        return True

    return e_norm in a_norm or a_norm in e_norm


@dataclass
class QueryResult:
    query: str
    query_type: str
    expected_doc: Optional[str]
    expected_chunk_ids: list[str]
    retrieved_chunk_ids: list[str]
    retrieved_docs: list[str]
    hit_chunk_ids: list[str]
    recall: Optional[float]
    precision: Optional[float]
    first_hit_rank: Optional[int]
    reciprocal_rank: float
    doc_found: Optional[bool]
    full_recall: Optional[bool]
    error: Optional[str] = None


def score_query(tq: TestQuery, data: dict[str, Any]) -> QueryResult:
    chunks = data.get("chunks", [])
    retrieved_ids = [c.get("id", "") for c in chunks]
    retrieved_docs = [c.get("document_keyword") or c.get("docnm_kwd") or c.get("document_name", "")
                      for c in chunks]

    expected_set = set(tq.expected_chunk_ids)
    hit_ids = [cid for cid in retrieved_ids if cid in expected_set]

    recall = (len(set(hit_ids)) / len(expected_set)) if expected_set else None
    precision = (len(hit_ids) / len(retrieved_ids)) if retrieved_ids else 0.0

    first_hit_rank = None
    for rank, cid in enumerate(retrieved_ids, start=1):
        if cid in expected_set:
            first_hit_rank = rank
            break
    reciprocal_rank = (1.0 / first_hit_rank) if first_hit_rank else 0.0

    doc_found = None
    if tq.expected_doc:
        doc_found = any(docs_match(tq.expected_doc, name) for name in retrieved_docs if name)

    full_recall = (set(hit_ids) == expected_set) if expected_set else None

    return QueryResult(
        query=tq.query,
        query_type=tq.query_type,
        expected_doc=tq.expected_doc,
        expected_chunk_ids=tq.expected_chunk_ids,
        retrieved_chunk_ids=retrieved_ids,
        retrieved_docs=retrieved_docs,
        hit_chunk_ids=hit_ids,
        recall=recall,
        precision=precision,
        first_hit_rank=first_hit_rank,
        reciprocal_rank=reciprocal_rank,
        doc_found=doc_found,
        full_recall=full_recall,
    )


# --------------------------------------------------------------------------
# Summary / reporting
# --------------------------------------------------------------------------

def summarize(results: list[QueryResult]) -> dict[str, Any]:
    def agg(subset: list[QueryResult]) -> dict[str, Any]:
        scored = [r for r in subset if r.error is None]
        recalls = [r.recall for r in scored if r.recall is not None]
        precisions = [r.precision for r in scored if r.precision is not None]
        rrs = [r.reciprocal_rank for r in scored]
        doc_hits = [r.doc_found for r in scored if r.doc_found is not None]
        full_recalls = [r.full_recall for r in scored if r.full_recall is not None]
        return {
            "count": len(subset),
            "errors": len(subset) - len(scored),
            "mean_recall": round(statistics.mean(recalls), 4) if recalls else None,
            "mean_precision": round(statistics.mean(precisions), 4) if precisions else None,
            "mrr": round(statistics.mean(rrs), 4) if rrs else None,
            "doc_hit_rate": round(sum(doc_hits) / len(doc_hits), 4) if doc_hits else None,
            "full_recall_rate": round(sum(full_recalls) / len(full_recalls), 4) if full_recalls else None,
        }

    by_type: dict[str, list[QueryResult]] = {}
    for r in results:
        by_type.setdefault(r.query_type, []).append(r)

    return {
        "overall": agg(results),
        "by_query_type": {qtype: agg(subset) for qtype, subset in sorted(by_type.items())},
    }


def print_summary(summary: dict[str, Any], k: int) -> None:
    def fmt(v):
        return f"{v:.3f}" if isinstance(v, (int, float)) else "n/a"

    print("\n" + "=" * 72)
    print(f"RETRIEVAL TEST SUMMARY  (top-{k} chunks retrieved per query)")
    print("=" * 72)

    overall = summary["overall"]
    print(f"Queries run:         {overall['count']}  ({overall['errors']} errored)")
    print(f"Mean recall@{k}:      {fmt(overall['mean_recall'])}")
    print(f"Mean precision@{k}:   {fmt(overall['mean_precision'])}")
    print(f"MRR:                 {fmt(overall['mrr'])}")
    print(f"Doc hit rate:        {fmt(overall['doc_hit_rate'])}")
    print(f"Full recall rate:    {fmt(overall['full_recall_rate'])}")

    by_type = summary["by_query_type"]
    if len(by_type) > 1:
        print("\nBy query_type:")
        header = f"{'type':<20}{'n':>5}{'recall':>10}{'precision':>12}{'mrr':>8}{'doc_hit':>10}{'full':>8}"
        print(header)
        print("-" * len(header))
        for qtype, m in by_type.items():
            print(f"{qtype:<20}{m['count']:>5}{fmt(m['mean_recall']):>10}"
                  f"{fmt(m['mean_precision']):>12}{fmt(m['mrr']):>8}"
                  f"{fmt(m['doc_hit_rate']):>10}{fmt(m['full_recall_rate']):>8}")
    print("=" * 72 + "\n")


def write_json_report(results: list[QueryResult], summary: dict[str, Any], cfg: Config,
                       run_id: str, timestamp: str) -> None:
    report = {
        "run_id": run_id,
        "timestamp": timestamp,
        "config": {
            "base_url": cfg.base_url,
            "dataset_ids": cfg.dataset_ids,
            "document_ids": cfg.document_ids,
            "k": cfg.k,
            "top_k": cfg.top_k,
            "similarity_threshold": cfg.similarity_threshold,
            "vector_weight": cfg.vector_weight,
            "rerank_id": cfg.rerank_id,
            "keyword": cfg.keyword,
        },
        "summary": summary,
        "results": [
            {
                "query": r.query,
                "query_type": r.query_type,
                "expected_doc": r.expected_doc,
                "expected_chunk_ids": r.expected_chunk_ids,
                "retrieved_chunk_ids": r.retrieved_chunk_ids,
                "retrieved_docs": r.retrieved_docs,
                "hit_chunk_ids": r.hit_chunk_ids,
                "recall": r.recall,
                "precision": r.precision,
                "first_hit_rank": r.first_hit_rank,
                "reciprocal_rank": r.reciprocal_rank,
                "doc_found": r.doc_found,
                "full_recall": r.full_recall,
                "error": r.error,
            }
            for r in results
        ],
    }
    cfg.output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote detailed JSON report to {cfg.output_path}")


def append_history(results: list[QueryResult], cfg: Config, run_id: str, timestamp: str) -> None:
    """Append one JSON-line per query to the history log.

    This is additive (never overwritten), so re-running with an expanded or
    edited test_queries.json builds up a per-query time series you can later
    load (e.g. `pandas.read_json(path, lines=True)`) and group by "query" to
    see how recall/precision/rank for that specific query trend across runs
    and across parameter changes (k, rerank_id, similarity_threshold, etc.).
    """
    path = cfg.history_path
    if path is None:
        return

    with path.open("a", encoding="utf-8") as f:
        for r in results:
            row = {
                "run_id": run_id,
                "timestamp": timestamp,
                "query": r.query,
                "query_type": r.query_type,
                "expected_doc": r.expected_doc,
                "recall": r.recall,
                "precision": r.precision,
                "first_hit_rank": r.first_hit_rank,
                "reciprocal_rank": round(r.reciprocal_rank, 4),
                "doc_found": r.doc_found,
                "full_recall": r.full_recall,
                "error": r.error,
                "k": cfg.k,
                "top_k": cfg.top_k,
                "similarity_threshold": cfg.similarity_threshold,
                "vector_weight": cfg.vector_weight,
                "rerank_id": cfg.rerank_id,
                "keyword": cfg.keyword,
            }
            f.write(json.dumps(row) + "\n")
    print(f"Appended {len(results)} rows to history log at {path}")


def write_csv_report(results: list[QueryResult], path: Path) -> None:
    fieldnames = ["query", "query_type", "expected_doc", "recall", "precision",
                  "first_hit_rank", "reciprocal_rank", "doc_found", "full_recall", "error"]
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in results:
            writer.writerow({
                "query": r.query,
                "query_type": r.query_type,
                "expected_doc": r.expected_doc or "",
                "recall": r.recall,
                "precision": r.precision,
                "first_hit_rank": r.first_hit_rank,
                "reciprocal_rank": round(r.reciprocal_rank, 4),
                "doc_found": r.doc_found,
                "full_recall": r.full_recall,
                "error": r.error or "",
            })
    print(f"Wrote CSV summary to {path}")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    cfg = parse_args(argv)
    queries = load_queries(cfg.queries_path)

    if not queries:
        print("No test queries found — nothing to do.", file=sys.stderr)
        return 1

    run_id = cfg.run_id
    timestamp = datetime.now(timezone.utc).isoformat()

    client = RagflowClient(cfg)
    results: list[QueryResult] = []

    print(f"Running {len(queries)} test queries against {cfg.base_url} "
          f"(dataset_ids={cfg.dataset_ids or 'n/a'}, k={cfg.k})  [run_id={run_id}]...\n")

    for i, tq in enumerate(queries, start=1):
        try:
            data = client.retrieve(tq.query)
            result = score_query(tq, data)
        except RagflowError as exc:
            result = QueryResult(
                query=tq.query, query_type=tq.query_type, expected_doc=tq.expected_doc,
                expected_chunk_ids=tq.expected_chunk_ids, retrieved_chunk_ids=[], retrieved_docs=[],
                hit_chunk_ids=[], recall=None, precision=None, first_hit_rank=None,
                reciprocal_rank=0.0, doc_found=None, full_recall=None, error=str(exc),
            )

        results.append(result)

        if cfg.verbose or result.error:
            status = f"ERROR: {result.error}" if result.error else (
                f"recall={result.recall} precision={result.precision:.2f} "
                f"first_hit_rank={result.first_hit_rank} doc_found={result.doc_found}"
            )
            print(f"[{i}/{len(queries)}] {tq.query_type:<10} {tq.query[:60]!r:<64} {status}")

        if cfg.sleep:
            time.sleep(cfg.sleep)

    summary = summarize(results)
    print_summary(summary, cfg.k)
    write_json_report(results, summary, cfg, run_id, timestamp)
    write_csv_report(results, cfg.csv_path)

    return 0


if __name__ == "__main__":
    sys.exit(main())
