"""
Step 2 of Path A: embed chunk text with Voyage AI directly.

This is a plain call to Voyage's public embeddings endpoint -- RAGFlow is
not involved at all in this step. A local content-hash cache means that
re-running this script after adding or editing a few documents only pays
for chunks that are new or changed, not the whole corpus again.

Input:  rag/export/output/chunks_raw.jsonl   (from export_chunks.py)
Output: rag/export/cache/embedding_cache.json   (hash -> embedding; persists across runs)
        rag/export/output/kb_vectors.npz        (float32 array, key 'vectors')
        rag/export/output/kb_manifest.jsonl     (same order as kb_vectors.npz rows)

Run:
    python embed_chunks.py
"""
import json
from pathlib import Path

import numpy as np
import voyageai

import config

BASE_DIR = Path(__file__).parent
INPUT_PATH = BASE_DIR / "output" / "chunks_raw.jsonl"

CACHE_DIR = BASE_DIR / "cache"
CACHE_DIR.mkdir(exist_ok=True)
CACHE_PATH = CACHE_DIR / "embedding_cache.json"

OUTPUT_DIR = BASE_DIR / "output"
VECTORS_PATH = OUTPUT_DIR / "kb_vectors.npz"
MANIFEST_PATH = OUTPUT_DIR / "kb_manifest.jsonl"

BATCH_SIZE = 128  # Voyage's documented batch size for the synchronous embed endpoint


def load_cache() -> dict:
    if CACHE_PATH.exists():
        with open(CACHE_PATH) as f:
            return json.load(f)
    return {}


def save_cache(cache: dict) -> None:
    with open(CACHE_PATH, "w") as f:
        json.dump(cache, f)


def main() -> None:
    config.print_config_summary()

    if not INPUT_PATH.exists():
        raise SystemExit(f"{INPUT_PATH} not found -- run export_chunks.py first.")

    records = [json.loads(line) for line in open(INPUT_PATH)]
    print(f"Loaded {len(records)} chunks from {INPUT_PATH}")

    cache = load_cache()
    print(f"Local cache currently holds {len(cache)} previously embedded chunks")

    # Dedupe by hash: identical chunk text (e.g. repeated boilerplate clauses,
    # or overlapping chunk boundaries) is embedded once no matter how many
    # records reference it.
    unique_hashes = sorted({r["hash"] for r in records})
    to_embed_hashes = [h for h in unique_hashes if h not in cache]
    print(
        f"{len(to_embed_hashes)} unique new/changed chunk(s) need embedding "
        f"(out of {len(unique_hashes)} unique chunks total)\n"
    )

    if to_embed_hashes:
        hash_to_text = {r["hash"]: r["content"] for r in records}
        vo = voyageai.Client(api_key=config.VOYAGE_API_KEY)

        for i in range(0, len(to_embed_hashes), BATCH_SIZE):
            batch_hashes = to_embed_hashes[i : i + BATCH_SIZE]
            batch_texts = [hash_to_text[h] for h in batch_hashes]

            result = vo.embed(batch_texts, model=config.VOYAGE_MODEL, input_type="document")

            for h, emb in zip(batch_hashes, result.embeddings):
                cache[h] = emb

            done = min(i + BATCH_SIZE, len(to_embed_hashes))
            print(f"  embedded {done}/{len(to_embed_hashes)}")
            save_cache(cache)  # persist incrementally so a crash mid-run doesn't lose progress
    else:
        print("Nothing new to embed -- reusing the existing cache entirely.")

    # Assemble the final ordered bundle from the (now fully populated) cache.
    vectors = np.array([cache[r["hash"]] for r in records], dtype=np.float32)
    np.savez(VECTORS_PATH, vectors=vectors)

    with open(MANIFEST_PATH, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print(f"\nWrote {vectors.shape[0]} vectors (dim={vectors.shape[1]}) to {VECTORS_PATH}")
    print(f"Wrote manifest to {MANIFEST_PATH}")


if __name__ == "__main__":
    main()
