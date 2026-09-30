#!/usr/bin/env python3
"""
Project Critical Orbit — Day 1, Lab 1, Step 02: index the flight manuals.

Reads the fictional runbooks in data/flight_manuals/, chunks them, embeds every
chunk with the squadron's embedding deployment, builds a hybrid
(keyword + vector + semantic) Azure AI Search index, and uploads the chunks.

Hard guarantee (mandated design): the vector field dimensions are derived from
a REAL embedding produced by the deployed model — not from a constant — and if
EXPECTED_EMBEDDING_DIMS disagrees with the measured size the script fails fast
with an explicit error instead of silently indexing mismatched vectors.

Usage:
    python src/02_index_flight_manuals.py              # create/recreate + load
    python src/02_index_flight_manuals.py --recreate   # drop index first
    python src/02_index_flight_manuals.py --dry-run    # chunk only, no Azure
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import uuid
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parents[2]
MANUALS_DIR = REPO_ROOT / "data" / "flight_manuals"
sys.path.insert(0, str(REPO_ROOT))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(REPO_ROOT / ".env")

INDEX_NAME = os.getenv("AZURE_SEARCH_INDEX_NAME", "flight-manuals")
CHUNK_CHARS = 1200       # target size per chunk
CHUNK_OVERLAP = 150      # overlap between consecutive chunks


def die(msg: str) -> NoReturn:
    print(f"[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)


def chunk_markdown(text: str, source: str) -> list[dict]:
    """Split a manual into heading-aware chunks with a small overlap.

    Everything before the first `##` (the H1 title and the FICTIONAL
    TRAINING DOCUMENT disclaimer) is merged into the first chunk instead of
    being silently dropped.
    """
    # Split on '## ' headings first, then size-cap each section.
    sections = re.split(r"(?m)^(## .+)$", text)
    preamble = sections[0].strip()
    parts: list[str] = []
    for i in range(1, len(sections), 2):
        part = sections[i] + (sections[i + 1] if i + 1 < len(sections) else "")
        if preamble:
            part = preamble + "\n\n" + part
            preamble = ""
        parts.append(part)
    if preamble:
        parts.insert(0, preamble)  # document had no '##' sections
    if not parts:
        parts = [text]

    chunks: list[dict] = []
    for part in parts:
        title_match = re.search(r"(?m)^#+ (.+)$", part)
        title = title_match.group(1).strip() if title_match else source
        start = 0
        while start < len(part):
            end = min(start + CHUNK_CHARS, len(part))
            chunks.append({"doc_title": title, "content": part[start:end].strip()})
            if end >= len(part):
                break
            start = end - CHUNK_OVERLAP
    return [c for c in chunks if c["content"]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--recreate", action="store_true", help="delete the index first (clean rebuild)")
    parser.add_argument("--dry-run", action="store_true", help="chunk + report only; no Azure calls")
    args = parser.parse_args()

    # --- chunk all manuals ----------------------------------------------------
    files = sorted(MANUALS_DIR.glob("*.md"))
    if not files:
        die(f"no manuals found in {MANUALS_DIR}")
    docs = []
    for f in files:
        for i, ch in enumerate(chunk_markdown(f.read_text(encoding="utf-8"), f.name)):
            docs.append(
                {
                    "id": uuid.uuid5(uuid.NAMESPACE_URL, f"{f.name}:{i}").hex,
                    "source_doc": f.name,
                    "chunk_id": i,
                    "doc_title": ch["doc_title"],
                    "content": ch["content"],
                }
            )
    print(f"[ok] chunked {len(files)} manuals -> {len(docs)} chunks")

    if args.dry_run:
        print("[dry-run] no Azure calls made.")
        return

    for var in ("AZURE_OPENAI_ENDPOINT", "AZURE_SEARCH_ENDPOINT", "EMBEDDING_MODEL_DEPLOYMENT"):
        if not os.getenv(var):
            die(f"missing .env var {var} — run scripts/setup-squadron.sh first")

    from azure.identity import DefaultAzureCredential
    from azure.search.documents.indexes import SearchIndexClient
    from azure.search.documents.indexes.models import (
        HnswAlgorithmConfiguration,
        SearchableField,
        SearchField,
        SearchFieldDataType,
        SearchIndex,
        SemanticConfiguration,
        SemanticField,
        SemanticPrioritizedFields,
        SemanticSearch,
        SimpleField,
        VectorSearch,
        VectorSearchProfile,
    )
    from azure.core.exceptions import ResourceNotFoundError
    from azure.search.documents import SearchIndexingBufferedSender
    from common.openai_client import get_openai_client

    credential = DefaultAzureCredential()
    search_endpoint = os.environ["AZURE_SEARCH_ENDPOINT"].rstrip("/")

    # --- measure the real embedding dimension ---------------------------------
    client = get_openai_client(credential)
    probe = client.embeddings.create(
        model=os.environ["EMBEDDING_MODEL_DEPLOYMENT"], input="dimension probe"
    )
    dims = len(probe.data[0].embedding)

    expected = int(os.getenv("EXPECTED_EMBEDDING_DIMS", "0") or 0)
    if expected and dims != expected:
        die(
            f"embedding dimension mismatch: deployed model produced {dims} dims "
            f"but EXPECTED_EMBEDDING_DIMS={expected}. Fix .env or the model "
            "deployment — do NOT index vectors of the wrong dimension."
        )
    print(f"[ok] measured embedding dimension: {dims}")

    # --- create / recreate the index ------------------------------------------
    index = SearchIndex(
        name=INDEX_NAME,
        fields=[
            SimpleField(name="id", type=SearchFieldDataType.String, key=True),
            SimpleField(name="source_doc", type=SearchFieldDataType.String, filterable=True),
            SimpleField(name="chunk_id", type=SearchFieldDataType.Int32, filterable=True),
            SearchableField(name="doc_title", type=SearchFieldDataType.String),
            SearchableField(name="content", type=SearchFieldDataType.String),
            SearchField(
                name="content_vector",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=dims,      # measured, not assumed
                vector_search_profile_name="vec-hnsw",
            ),
        ],
        vector_search=VectorSearch(
            algorithms=[HnswAlgorithmConfiguration(name="hnsw")],
            profiles=[VectorSearchProfile(name="vec-hnsw", algorithm_configuration_name="hnsw")],
        ),
        semantic_search=SemanticSearch(
            configurations=[
                SemanticConfiguration(
                    name="semantic-main",
                    prioritized_fields=SemanticPrioritizedFields(
                        title_field=SemanticField(field_name="doc_title"),
                        content_fields=[SemanticField(field_name="content")],
                    ),
                )
            ]
        ),
    )

    with SearchIndexClient(endpoint=search_endpoint, credential=credential) as sic:
        # Compare with any existing index BEFORE create_or_update — a dimension
        # mismatch otherwise fails with a cryptic service error.
        try:
            existing = sic.get_index(INDEX_NAME)
        except ResourceNotFoundError:
            existing = None
        if existing is not None:
            old_dims = next(
                (f.vector_search_dimensions for f in existing.fields
                 if f.name == "content_vector"),
                None,
            )
            if old_dims is not None and old_dims != dims and not args.recreate:
                die(
                    f"index '{INDEX_NAME}' already exists with vector "
                    f"dimension {old_dims}, but the deployed model produces "
                    f"{dims}-dim vectors. Either fix the model deployment or "
                    f"re-run with --recreate to rebuild the index."
                )
        if args.recreate:
            try:
                sic.delete_index(INDEX_NAME)
                print(f"[ok] dropped existing index '{INDEX_NAME}'")
            except ResourceNotFoundError:
                pass  # absent is fine; every other failure (auth etc.) surfaces
            except Exception as exc:  # noqa: BLE001
                die(f"could not delete index '{INDEX_NAME}': {exc}")
        try:
            sic.create_or_update_index(index)
        except Exception as exc:  # noqa: BLE001
            die(f"create_or_update_index failed for '{INDEX_NAME}': {exc}")
        print(f"[ok] index '{INDEX_NAME}' ready (vector={dims}d hnsw, semantic=semantic-main)")

    # --- embed + upload ---------------------------------------------------------
    vectors = []
    batch = [d["content"] for d in docs]
    resp = client.embeddings.create(model=os.environ["EMBEDDING_MODEL_DEPLOYMENT"], input=batch)
    for i, e in enumerate(resp.data):
        vectors.append(e.embedding)
        docs[i]["content_vector"] = e.embedding
    assert all(len(v) == dims for v in vectors), "inconsistent vector sizes"

    with SearchIndexingBufferedSender(
        endpoint=search_endpoint, index_name=INDEX_NAME, credential=credential
    ) as sender:
        sender.upload_documents(documents=docs)
    print(f"[ok] uploaded {len(docs)} embedded chunks to '{INDEX_NAME}'")
    print("\nDONE — flight manuals are indexed. Next: python src/03_query_flight_manual.py")


if __name__ == "__main__":
    main()
