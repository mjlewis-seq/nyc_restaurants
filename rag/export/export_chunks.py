"""
Step 1 of Path A: export chunk text + metadata from RAGFlow.

This calls RAGFlow's public REST API directly via `requests` -- no Docker,
no direct Elasticsearch/Infinity access, no internal database queries, and
no dependency on the `ragflow-sdk` package (which was found to return a
401 in testing even with a confirmed-valid key -- likely a version
mismatch between the SDK and this RAGFlow server). Everything here mirrors
requests that were verified to work with plain curl.

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

import requests

import config

OUTPUT_DIR = Path(__file__).parent / "output"
OUTPUT_DIR.mkdir(exist_ok=True)
OUTPUT_PATH = OUTPUT_DIR / "chunks_raw.jsonl"

PAGE_SIZE = 100  # well above the 30-per-page default some RAGFlow versions
                 # silently fall back to (see infiniflow/ragflow#10097) --
                 # we still loop pages below rather than trust one call.

# Candidate keys RAGFlow may use for auto-extracted document metadata,
# checked in order. If none of these match what your RAGFlow version
# actually returns, the script prints the raw document JSON for the first
# document so you can see the real field name and adjust DOC_METADATA_KEYS.
DOC_METADATA_KEYS = ("meta_fields", "metadata", "meta")


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def api_get(session: requests.Session, path: str, params: dict = None) -> dict:
    url = f"{config.RAGFLOW_BASE_URL.rstrip('/')}{path}"
    resp = session.get(url, params=params or {})
    resp.raise_for_status()
    body = resp.json()
    if body.get("code") != 0:
        raise RuntimeError(f"RAGFlow API error on {path}: {body}")
    return body["data"]


def find_dataset_id(session: requests.Session, name: str) -> str:
    data = api_get(session, "/api/v1/datasets", {"page": 1, "page_size": PAGE_SIZE})
    datasets = data if isinstance(data, list) else data.get("docs", data)
    for ds in datasets:
        if ds["name"] == name:
            return ds["id"]
    available = ", ".join(f"'{ds['name']}'" for ds in datasets)
    raise SystemExit(
        f"No dataset found named '{name}'.\n"
        f"Datasets visible to this API key: {available or '(none)'}\n"
        f"Check RAGFLOW_DATASET_NAME in your .env file -- note hyphens vs "
        f"underscores matter, it must match exactly."
    )


def list_all_documents(session: requests.Session, dataset_id: str) -> list:
    docs = []
    page = 1
    while True:
        data = api_get(
            session,
            f"/api/v1/datasets/{dataset_id}/documents",
            {"page": page, "page_size": PAGE_SIZE},
        )
        batch = data["docs"]
        docs.extend(batch)
        if len(batch) < PAGE_SIZE:
            break
        page += 1
    return docs


def list_all_chunks(session: requests.Session, dataset_id: str, document_id: str) -> list:
    chunks = []
    seen_ids = set()
    page = 1
    while True:
        data = api_get(
            session,
            f"/api/v1/datasets/{dataset_id}/documents/{document_id}/chunks",
            {"page": page, "page_size": PAGE_SIZE},
        )
        batch = data["chunks"]
        new_this_page = 0
        for c in batch:
            if c["id"] in seen_ids:
                continue  # defensive dedup, see infiniflow/ragflow#10097
            seen_ids.add(c["id"])
            chunks.append(c)
            new_this_page += 1
        if len(batch) < PAGE_SIZE or new_this_page == 0:
            break
        page += 1
    return chunks


def extract_doc_metadata(doc: dict) -> dict:
    for key in DOC_METADATA_KEYS:
        if doc.get(key):
            return doc[key]
    return {}


def main() -> None:
    config.print_config_summary()

    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {config.RAGFLOW_API_KEY}"})

    dataset_id = find_dataset_id(session, config.RAGFLOW_DATASET_NAME)
    documents = list_all_documents(session, dataset_id)
    print(f"Found {len(documents)} document(s) in dataset '{config.RAGFLOW_DATASET_NAME}'\n")

    records = []
    printed_debug_doc = False

    for doc in documents:
        doc_metadata = extract_doc_metadata(doc)
        if not doc_metadata and not printed_debug_doc:
            print(
                "NOTE: no metadata found under keys "
                f"{DOC_METADATA_KEYS} on the first document. Raw document "
                "JSON below -- check for the real field name and update "
                "DOC_METADATA_KEYS at the top of this script if needed:"
            )
            print(json.dumps(doc, indent=2)[:2000])
            printed_debug_doc = True

        chunks = list_all_chunks(session, dataset_id, doc["id"])
        for chunk in chunks:
            content = chunk["content"]
            records.append({
                "chunk_id": chunk["id"],
                "doc": doc["name"],
                "content": content,
                "metadata": doc_metadata,
                "hash": content_hash(content),
            })

        expected = doc.get("chunk_count")
        flag = ""
        if expected is not None and len(chunks) != expected:
            flag = f"  <-- WARNING: expected {expected} chunks per RAGFlow, got {len(chunks)}"
        print(f"  {doc['name']}: {len(chunks)} chunks{flag}")

    with open(OUTPUT_PATH, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print(f"\nWrote {len(records)} chunks to {OUTPUT_PATH}")
    if len(records) == 0:
        print("WARNING: zero chunks exported -- check dataset name and parsing status in RAGFlow.")


if __name__ == "__main__":
    main()
