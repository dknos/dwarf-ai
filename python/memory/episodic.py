"""
episodic.py — Per-dwarf episodic memory backed by ChromaDB.

Each dwarf gets its own collection: dwarf_memories_{unit_id}
Memory types:
  core     — permanent, high-emotion events
  episodic — normal significant events
  mundane  — low-significance daily noise

Decay rates:
  NEVER   — core memories, never expire
  LOW     — consolidated journal entries
  MEDIUM  — normal episodic events
  HIGH    — mundane noise, prune first
"""
from __future__ import annotations

import logging
import time
from typing import Optional

import chromadb

logger = logging.getLogger(__name__)

_CHROMA_DEFAULT_PATH = "/home/nemoclaw/dwarf-ai/chroma"

# Valid decay rates
DECAY_RATES = {"NEVER", "LOW", "MEDIUM", "HIGH"}
# Valid memory types
MEMORY_TYPES = {"core", "episodic", "mundane"}


class EpisodicMemory:
    """
    Manages per-dwarf episodic memory collections in ChromaDB.
    Pass chroma_dir as a string path; ChromaDB PersistentClient requires a path string.
    """

    def __init__(self, chroma_dir: str = _CHROMA_DEFAULT_PATH):
        self._chroma_dir = chroma_dir
        self._client = chromadb.PersistentClient(path=chroma_dir)
        logger.info("EpisodicMemory initialised at %s", chroma_dir)

    def _collection(self, unit_id: int) -> chromadb.Collection:
        """Return (or create) the ChromaDB collection for this dwarf."""
        name = f"dwarf_memories_{unit_id}"
        return self._client.get_or_create_collection(name=name)

    def add_event(
        self,
        unit_id: int,
        event_text: str,
        emotional_weight: int,
        decay_rate: str = "MEDIUM",
        memory_type: str = "episodic",
        tick: Optional[int] = None,
    ) -> str:
        """
        Store a new memory event for unit_id.

        Args:
            unit_id:         Dwarf unit ID.
            event_text:      Plain-English description of the event.
            emotional_weight: 0-100 significance score.
            decay_rate:      NEVER / LOW / MEDIUM / HIGH
            memory_type:     core / episodic / mundane
            tick:            Game tick at event time (defaults to wall clock).

        Returns:
            The generated memory ID string.
        """
        if decay_rate not in DECAY_RATES:
            logger.warning("Unknown decay_rate %r — defaulting to MEDIUM", decay_rate)
            decay_rate = "MEDIUM"
        if memory_type not in MEMORY_TYPES:
            logger.warning("Unknown memory_type %r — defaulting to episodic", memory_type)
            memory_type = "episodic"

        col = self._collection(unit_id)
        mem_id = f"{unit_id}-{int(time.time() * 1000)}"
        col.add(
            ids=[mem_id],
            documents=[event_text],
            metadatas=[
                {
                    "unit_id": unit_id,
                    "tick": tick if tick is not None else -1,
                    "emotional_weight": max(0, min(100, emotional_weight)),
                    "decay_rate": decay_rate,
                    "memory_type": memory_type,
                }
            ],
        )
        logger.debug(
            "add_event unit=%d id=%s type=%s ew=%d decay=%s",
            unit_id, mem_id, memory_type, emotional_weight, decay_rate,
        )
        return mem_id

    def query(
        self,
        unit_id: int,
        topic: str,
        top_k: int = 3,
    ) -> list[str]:
        """
        Semantic search over this dwarf's memories.

        Args:
            unit_id: Dwarf unit ID.
            topic:   Query text (usually the player's input or current situation).
            top_k:   Number of results to return.

        Returns:
            List of memory document strings, most relevant first.
        """
        col = self._collection(unit_id)
        count = col.count()
        if count == 0:
            return []

        actual_k = min(top_k, count)
        results = col.query(query_texts=[topic], n_results=actual_k)
        documents = results.get("documents", [[]])[0]
        return [d for d in documents if d]

    def get_core_memories(self, unit_id: int) -> list[str]:
        """
        Return all core (permanent) memories for this dwarf.

        Returns:
            List of memory document strings.
        """
        col = self._collection(unit_id)
        if col.count() == 0:
            return []

        results = col.get(where={"memory_type": "core"})
        documents = results.get("documents", [])
        return [d for d in documents if d]

    def get_recent_episodic(
        self,
        unit_id: int,
        since_tick: int,
        limit: int = 20,
    ) -> list[dict]:
        """
        Return episodic memories since a given game tick, for consolidation.

        Returns:
            List of dicts with keys: id, document, metadata.
        """
        col = self._collection(unit_id)
        if col.count() == 0:
            return []

        results = col.get(
            where={
                "$and": [
                    {"memory_type": {"$in": ["episodic", "mundane"]}},
                    {"tick": {"$gte": since_tick}},
                ]
            }
        )
        ids = results.get("ids", [])
        docs = results.get("documents", [])
        metas = results.get("metadatas", [])
        out = []
        for i, doc_id in enumerate(ids):
            out.append({
                "id": doc_id,
                "document": docs[i] if i < len(docs) else "",
                "metadata": metas[i] if i < len(metas) else {},
            })
            if len(out) >= limit:
                break
        return out
