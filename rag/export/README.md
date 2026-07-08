# RAGFlow export pipeline (Path A)

Exports parsed chunks out of RAGFlow and re-embeds them directly via Voyage
AI, producing a portable knowledge-base bundle your teammate can query
locally -- no running RAGFlow instance, no server, no VM required on their
end.

## Setup (one time)

```bash
cd rag/export
python -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt
cp .env.example .env
```

Now open `.env` and fill in real values. **`.env` is gitignored -- it will
never be committed.** See "API keys you'll need" below for where to get them.

## Run the pipeline

```bash
python export_chunks.py     # RAGFlow -> rag/export/output/chunks_raw.jsonl
python embed_chunks.py       # Voyage AI -> rag/export/output/kb_vectors.npz + kb_manifest.jsonl
python build_kb_bundle.py    # packages both into rag/export/output/nyc_health_code_kb_<date>.zip
```

Re-running `export_chunks.py` + `embed_chunks.py` later (after adding or
editing documents in RAGFlow) is safe and cheap: `embed_chunks.py` caches
embeddings by content hash in `cache/embedding_cache.json`, so only new or
changed chunks get sent to Voyage again.

## Sharing the result

Hand your teammate the `.zip` from `output/` directly (GitHub Release
asset, shared drive, Git LFS -- **not** a plain git commit; the vectors are
a binary blob that won't diff meaningfully in git history). The zip
contains its own `README.txt` explaining how to query it with just NumPy
and a Voyage API key -- no RAGFlow SDK needed on their side.

## API keys you'll need

| Variable | Where to get it | Secret? |
|---|---|---|
| `RAGFLOW_API_KEY` | RAGFlow web UI -> your avatar (top right) -> API key | Yes |
| `VOYAGE_API_KEY` | https://dashboard.voyageai.com/ | Yes |
| `RAGFLOW_BASE_URL` | Wherever your RAGFlow instance is reachable (default `http://localhost:9380`) | No -- just an address |
| `RAGFLOW_DATASET_NAME` | The dataset name as it appears in RAGFlow | No |

Only `RAGFLOW_API_KEY` and `VOYAGE_API_KEY` are actual secrets. Both live
only in your local `.env` file, which is gitignored and never leaves your
machine as part of this repo.

## How the keys stay out of git

- `.env` holds the real values and is listed in `.gitignore` -- git will
  never track it, even if you `git add .`.
- `.env.example` is the committed template -- it has the variable names but
  placeholder values, so collaborators know what to fill in without ever
  seeing your actual keys.
- `config.py` loads `.env` at runtime and refuses to start if a key is
  missing, but it never prints a full key value -- only a masked preview
  like `abcd...wxyz` -- so accidental exposure via terminal scrollback or
  copy-pasted logs isn't a risk either.
- `cache/` and `output/` are also gitignored, since the generated files
  contain your full corpus text and vectors -- not credentials, but still
  not something to accumulate in git history.

Before your first commit of this folder, it's worth double-checking with
`git status` that `.env` doesn't show up as a tracked or staged file.
