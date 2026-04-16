"""
legends_rag.py — Local RAG index over Dwarf Fortress legends.xml.

LegendIndex:
  build(legends_xml_path)  — parse legends.xml, embed, store in ChromaDB
  query(question, top_k=5) — return list of relevant passage strings
  is_built()               — bool, True if collection exists and has documents

Embedding: sentence-transformers all-MiniLM-L6-v2  (local, no API cost)
Vector store: ChromaDB persistent collection "df_legends"
              stored at /home/nemoclaw/dwarf-ai/chroma
"""
from __future__ import annotations

import logging
import os
import xml.etree.ElementTree as ET
from typing import Optional

logger = logging.getLogger(__name__)

CHROMA_DIR       = "/home/nemoclaw/dwarf-ai/chroma"
COLLECTION_NAME  = "df_legends"
EMBED_MODEL      = "all-MiniLM-L6-v2"

# Tag groups we parse from legends.xml
_SECTION_TAGS = {
    "historical_figures": "historical_figure",
    "events":             "event",
    "entities":           "entity",
    "sites":              "site",
}


# ─── XML → text passages ──────────────────────────────────────────────────────

def _element_to_text(elem: ET.Element) -> str:
    """Flatten an XML element's children into a plain-English-ish passage."""
    parts: list[str] = []
    tag = elem.tag.replace("_", " ")
    id_val = elem.findtext("id") or elem.get("id") or "?"
    name = elem.findtext("name") or ""
    if name:
        parts.append(f"{tag} #{id_val}: {name}.")
    else:
        parts.append(f"{tag} #{id_val}.")

    for child in elem:
        if child.tag in ("id",):  # already used
            continue
        key   = child.tag.replace("_", " ")
        value = (child.text or "").strip()
        if value:
            parts.append(f"{key}: {value}.")

    return " ".join(parts)


def _parse_sections(xml_path: str) -> list[dict]:
    """
    Parse legends.xml and return a list of passage dicts:
      {id, text, section}

    Yields one passage per child element inside each of the four top-level
    sections we care about.  Unknown sections are silently skipped.
    """
    logger.info("Parsing legends XML: %s", xml_path)
    try:
        tree = ET.parse(xml_path)
    except ET.ParseError as exc:
        logger.error("XML parse error: %s", exc)
        return []

    root = tree.getroot()
    passages: list[dict] = []

    for section_tag, child_tag in _SECTION_TAGS.items():
        section_elem = root.find(section_tag)
        if section_elem is None:
            logger.debug("Section <%s> not found in legends.xml", section_tag)
            continue

        for child in section_elem:
            if child.tag != child_tag:
                continue
            text = _element_to_text(child)
            if not text.strip():
                continue
            uid = child.findtext("id") or child.get("id") or str(len(passages))
            passages.append({
                "id":      f"{section_tag}_{uid}",
                "text":    text,
                "section": section_tag,
            })

    logger.info("Parsed %d passages from legends.xml", len(passages))
    return passages


# ─── LegendIndex ──────────────────────────────────────────────────────────────

class LegendIndex:
    """Persistent vector index over a Dwarf Fortress legends.xml."""

    def __init__(
        self,
        chroma_dir:  str = CHROMA_DIR,
        collection:  str = COLLECTION_NAME,
        embed_model: str = EMBED_MODEL,
    ) -> None:
        self._chroma_dir   = chroma_dir
        self._collection   = collection
        self._embed_model  = embed_model
        self._client       = None   # chromadb.PersistentClient
        self._col          = None   # chromadb collection handle
        self._embedder     = None   # SentenceTransformer

    # ── lazy init helpers ────────────────────────────────────────────────────

    def _get_chroma(self):
        if self._client is None:
            import chromadb  # type: ignore
            os.makedirs(self._chroma_dir, exist_ok=True)
            self._client = chromadb.PersistentClient(path=self._chroma_dir)
        return self._client

    def _get_collection(self, create: bool = False):
        client = self._get_chroma()
        if self._col is None:
            if create:
                self._col = client.get_or_create_collection(
                    name=self._collection,
                    metadata={"hnsw:space": "cosine"},
                )
            else:
                try:
                    self._col = client.get_collection(self._collection)
                except Exception:
                    return None
        return self._col

    def _get_embedder(self):
        if self._embedder is None:
            from sentence_transformers import SentenceTransformer  # type: ignore
            logger.info("Loading sentence-transformer: %s", self._embed_model)
            self._embedder = SentenceTransformer(self._embed_model)
        return self._embedder

    # ── public API ───────────────────────────────────────────────────────────

    def is_built(self) -> bool:
        """Return True if the ChromaDB collection exists and contains documents."""
        try:
            col = self._get_collection(create=False)
            if col is None:
                return False
            return col.count() > 0
        except Exception:
            return False

    def build(self, legends_xml_path: str, batch_size: int = 256) -> None:
        """
        Parse legends.xml, embed every passage, and upsert into ChromaDB.

        Safe to call multiple times — uses upsert so re-running with the same
        XML simply refreshes entries without duplicating them.

        Args:
            legends_xml_path: Absolute path to the legends.xml export.
            batch_size:       Number of passages to embed/upsert per batch.
        """
        if not os.path.isfile(legends_xml_path):
            raise FileNotFoundError(f"legends.xml not found: {legends_xml_path}")

        passages = _parse_sections(legends_xml_path)
        if not passages:
            logger.warning("No passages extracted — nothing to index.")
            return

        embedder = self._get_embedder()
        col      = self._get_collection(create=True)

        total = len(passages)
        logger.info("Embedding and indexing %d passages …", total)

        for start in range(0, total, batch_size):
            batch = passages[start : start + batch_size]
            texts = [p["text"] for p in batch]
            ids   = [p["id"]   for p in batch]
            metas = [{"section": p["section"]} for p in batch]

            embeddings = embedder.encode(texts, show_progress_bar=False).tolist()

            col.upsert(
                ids        = ids,
                documents  = texts,
                embeddings = embeddings,
                metadatas  = metas,
            )
            logger.debug("Indexed batch %d–%d", start, start + len(batch) - 1)

        logger.info("LegendIndex build complete: %d passages stored in '%s'",
                    total, self._collection)

    def query(self, question: str, top_k: int = 5) -> list[str]:
        """
        Query the index and return the top_k most relevant passage strings.

        Returns an empty list if the index is not built or if the query fails.
        """
        if not self.is_built():
            logger.debug("LegendIndex.query called but index is not built")
            return []

        try:
            embedder = self._get_embedder()
            vec = embedder.encode([question], show_progress_bar=False).tolist()[0]

            col     = self._get_collection(create=False)
            results = col.query(
                query_embeddings = [vec],
                n_results        = min(top_k, col.count()),
                include          = ["documents"],
            )
            docs = results.get("documents", [[]])[0]
            return [str(d) for d in docs if d]
        except Exception as exc:
            logger.error("LegendIndex.query failed: %s", exc)
            return []


# ─── CLI helper ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    parser = argparse.ArgumentParser(description="Build or query the dwarf-ai legends RAG index.")
    sub = parser.add_subparsers(dest="cmd")

    build_p = sub.add_parser("build", help="Build index from legends.xml")
    build_p.add_argument("xml", help="Path to legends.xml")

    query_p = sub.add_parser("query", help="Query the index")
    query_p.add_argument("question", nargs="+", help="Question text")
    query_p.add_argument("--top-k", type=int, default=5)

    args = parser.parse_args()
    idx  = LegendIndex()

    if args.cmd == "build":
        idx.build(args.xml)
        print(f"Built. Collection has {idx._get_collection().count()} docs.")

    elif args.cmd == "query":
        q       = " ".join(args.question)
        results = idx.query(q, top_k=args.top_k)
        for i, r in enumerate(results, 1):
            print(f"\n[{i}] {r}")

    else:
        parser.print_help()
