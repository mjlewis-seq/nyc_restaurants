"""
Step 3 of Path A: package the manifest + vectors into a single, dated
bundle ready to hand off to a teammate.

Note: this bundle contains a large binary vector array, so it won't
diff meaningfully in git no matter the format. Share it as a GitHub
Release asset, a shared drive link, or via Git LFS -- not a regular
git commit. Keep these scripts themselves in git; distribute the
generated .zip separately.

Input:  rag/export/output/kb_manifest.jsonl
        rag/export/output/kb_vectors.npz
Output: rag/export/output/nyc_health_codes_kb_<date>.zip

Run:
    python build_kb_bundle.py
"""
import zipfile
from datetime import date
from pathlib import Path

BASE_DIR = Path(__file__).parent
OUTPUT_DIR = BASE_DIR / "output"

MANIFEST_PATH = OUTPUT_DIR / "kb_manifest.jsonl"
VECTORS_PATH = OUTPUT_DIR / "kb_vectors.npz"

TODAY = date.today().isoformat()
BUNDLE_PATH = OUTPUT_DIR / f"nyc_health_codes_kb_{TODAY}.zip"

README_TEXT = """NYC Health Code knowledge base export
Generated: {date}

Files:
  kb_manifest.jsonl  - one JSON object per chunk:
                       {{"chunk_id", "doc", "content", "metadata", "hash"}}
  kb_vectors.npz     - float32 array under key 'vectors'; row i corresponds
                       to line i of kb_manifest.jsonl (same order, same count)

To query this bundle (no RAGFlow, no server, no VM required):
  1. Load kb_manifest.jsonl and kb_vectors.npz.
  2. Embed the user's question with Voyage AI:
       model="voyage-4", input_type="query"
     (note: query-time model is voyage-4, not voyage-4-large -- this
     matches the asymmetric indexing strategy used to build this export;
     voyage-4 and voyage-4-large are compatible/comparable in the same
     vector space).
  3. Compute similarity between the query vector and every row of
     kb_vectors.npz. Voyage embeddings are pre-normalized, so a plain dot
     product is equivalent to cosine similarity:
       scores = query_vector @ vectors.T
  4. Take the top-k highest-scoring rows and read the corresponding chunk
     text from kb_manifest.jsonl at the same row index.

Requires a Voyage AI API key at query time, to embed the incoming
question. No other credentials or services are needed to use this bundle.
"""


def main() -> None:
    if not MANIFEST_PATH.exists() or not VECTORS_PATH.exists():
        raise SystemExit("Run export_chunks.py and embed_chunks.py first.")

    readme_path = OUTPUT_DIR / "README.txt"
    readme_path.write_text(README_TEXT.format(date=TODAY))

    with zipfile.ZipFile(BUNDLE_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(MANIFEST_PATH, arcname="kb_manifest.jsonl")
        zf.write(VECTORS_PATH, arcname="kb_vectors.npz")
        zf.write(readme_path, arcname="README.txt")

    print(f"Bundle written to {BUNDLE_PATH}")
    print("Share this file directly (GitHub Release asset, shared drive, Git LFS) --")
    print("do not add it to a regular git commit; it's a binary blob that won't diff.")


if __name__ == "__main__":
    main()
