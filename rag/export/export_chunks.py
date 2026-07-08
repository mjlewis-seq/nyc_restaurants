"""
Step 1 of Path A: export chunk text + metadata from RAGFlow.

This talks to RAGFlow's public Python SDK only -- no Docker, no direct
Elasticsearch/Infinity access, no internal database queries. It reads
whatever dataset RAGFLOW_DATASET_NAME points at and writes every chunk's
text and metadata to a local JSONL file.

Input:  none (reads live from your running RAGFlow instance)
Output: rag/export/output/chunks_raw.jsonl
        one JSON object per line:
        {"chunk_id", "doc", "content", "metadata", "hash"}

Run:
    python export_chunks.py
"""
import hashlib
import json
from pathlib import Path

from ragflow_sdk import RAGFlow

import config

OUTPUT_DIR = Path(__file__).parent / "output"
OUTPUT_DIR.mkdir(exist_ok=True)
OUTPUT_PATH = OUTPUT_DIR / "chunks_raw.jsonl"


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> None:
    config.print_config_summary()

    rag = RAGFlow(api_key=config.RAGFLOW_API_KEY, base_url=config.RAGFLOW_BASE_URL)

    datasets = rag.list_datasets(name=config.RAGFLOW_DATASET_NAME)
    if not datasets:
        raise SystemExit(
            f"No dataset found named '{config.RAGFLOW_DATASET_NAME}'. "
            f"Check RAGFLOW_DATASET_NAME in your .env file."
        )
    dataset = datasets[0]

    documents = dataset.list_documents()
    print(f"Found {len(documents)} document(s) in dataset '{dataset.name}'\n")

    records = []
    seen_chunk_ids = set()

    for doc in documents:
        chunks = doc.list_chunks()
        added = 0
        for chunk in chunks:
            # Guard against a known pagination-duplication issue seen in some
            # RAGFlow versions (infiniflow/ragflow#10097): skip repeats rather
            # than trusting offset/limit to behave correctly.
            if chunk.id in seen_chunk_ids:
                continue
            seen_chunk_ids.add(chunk.id)

            content = chunk.content
            record = {
                "chunk_id": chunk.id,
                "doc": doc.name,
                "content": content,
                "metadata": getattr(chunk, "metadata", {}) or {},
                "hash": content_hash(content),
            }
            records.append(record)
            added += 1

        expected = getattr(doc, "chunk_count", None)
        flag = ""
        if expected is not None and added != expected:
            flag = f"  <-- WARNING: expected {expected} chunks per RAGFlow, got {added}"
        print(f"  {doc.name}: {added} chunks{flag}")

    with open(OUTPUT_PATH, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print(f"\nWrote {len(records)} chunks to {OUTPUT_PATH}")
    if len(records) == 0:
        print("WARNING: zero chunks exported -- check dataset name and parsing status in RAGFlow.")


if __name__ == "__main__":
    main()
