"""H7 regression: the markdown chunker must keep the H1 title and the
'FICTIONAL TRAINING DOCUMENT' disclaimer that precede the first `##`."""

import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MOD_PATH = REPO_ROOT / "day1" / "src" / "02_index_flight_manuals.py"
MANUALS = REPO_ROOT / "data" / "flight_manuals"


def _load():
    spec = importlib.util.spec_from_file_location("index_flight_manuals", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def mod():
    return _load()


def test_preamble_preserved_in_real_manuals(mod):
    manuals = sorted(MANUALS.glob("*.md"))
    assert manuals, "no manuals found"
    for f in manuals:
        chunks = mod.chunk_markdown(f.read_text(encoding="utf-8"), f.name)
        joined = "\n".join(c["content"] for c in chunks)
        assert "FICTIONAL TRAINING DOCUMENT" in joined, f"{f.name} lost the disclaimer"
        # the H1 line must survive too
        h1 = next(
            line.lstrip("# ").strip()
            for line in f.read_text(encoding="utf-8").splitlines()
            if line.startswith("# ")
        )
        assert h1 in joined, f"{f.name} lost the H1 title"
        assert chunks[0]["doc_title"] == h1


def test_preamble_merges_into_first_chunk(mod):
    text = "# Title\n\n> disclaimer line\n\n## Section A\nbody a\n\n## Section B\nbody b"
    chunks = mod.chunk_markdown(text, "x.md")
    assert "disclaimer line" in chunks[0]["content"]
    assert chunks[0]["doc_title"] == "Title"
    assert "Section B" in chunks[-1]["content"]


def test_document_without_sections_keeps_preamble(mod):
    chunks = mod.chunk_markdown("# Only A Title\n\nsome prose", "x.md")
    assert "some prose" in chunks[0]["content"]
    assert chunks[0]["doc_title"] == "Only A Title"
