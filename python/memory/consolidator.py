"""
consolidator.py — Sleep consolidation for dwarf episodic memory.

Triggered when bridge receives a context with type="sleep_event".

Workflow:
  1. Collect that day's episodic memories (tick-range since last sleep).
  2. Call LLM for a 2-3 sentence personal journal entry.
  3. Store the summary with decay_rate=LOW for high persistence.
  4. Promote any events with emotional_weight > 80 to core_memories
     with decay_rate=NEVER.
"""
from __future__ import annotations

import logging
from typing import Optional

from memory.episodic import EpisodicMemory
from llm_client import complete_text

logger = logging.getLogger(__name__)

_JOURNAL_SYSTEM_PROMPT = (
    "You are writing a brief personal journal entry from the perspective of a Dwarf "
    "Fortress dwarf. Write in first-person past tense. Keep it to 2-3 sentences. "
    "Capture the emotional tone of the day. Do not mention game mechanics."
)

# Emotional weight threshold that promotes a memory to core
_CORE_THRESHOLD = 80


class SleepConsolidator:
    """
    Consolidates a dwarf's episodic memories at sleep time.
    """

    def __init__(self, episodic: EpisodicMemory):
        self._episodic = episodic

    def consolidate(self, unit_id: int, ctx: dict) -> Optional[str]:
        """
        Run sleep consolidation for unit_id.

        Args:
            unit_id: Dwarf unit ID.
            ctx:     The sleep_event context dict (may contain 'tick', 'last_sleep_tick').

        Returns:
            The journal summary string, or None if no memories to consolidate.
        """
        tick: int = ctx.get("tick", -1)
        # If Lua doesn't send last_sleep_tick, fall back to 0 (get all memories)
        since_tick: int = ctx.get("last_sleep_tick", 0)

        memories = self._episodic.get_recent_episodic(
            unit_id=unit_id,
            since_tick=since_tick,
        )

        if not memories:
            logger.debug("consolidate unit=%d — no episodic memories to consolidate", unit_id)
            return None

        # --- Promote high-emotion events to core ---
        for mem in memories:
            ew = mem.get("metadata", {}).get("emotional_weight", 0)
            if ew > _CORE_THRESHOLD:
                self._episodic.add_event(
                    unit_id=unit_id,
                    event_text=mem["document"],
                    emotional_weight=ew,
                    decay_rate="NEVER",
                    memory_type="core",
                    tick=mem.get("metadata", {}).get("tick"),
                )
                logger.debug(
                    "consolidate unit=%d — promoted to core: %s", unit_id, mem["id"]
                )

        # --- Build journal summary via LLM ---
        events_text = "\n".join(
            f"- {m['document']}" for m in memories
        )
        user_message = (
            f"Here are the events from today:\n{events_text}\n\n"
            "Write a 2-3 sentence journal entry summarising this dwarf's day."
        )

        try:
            summary = complete_text(
                system_prompt=_JOURNAL_SYSTEM_PROMPT,
                user_message=user_message,
            )
        except Exception as exc:
            logger.error("LLM journal call failed for unit=%d: %s", unit_id, exc)
            return None

        if not summary:
            logger.warning("consolidate unit=%d — LLM returned empty summary", unit_id)
            return None

        # Store summary as a consolidated episodic memory with LOW decay
        self._episodic.add_event(
            unit_id=unit_id,
            event_text=summary,
            emotional_weight=50,
            decay_rate="LOW",
            memory_type="episodic",
            tick=tick,
        )
        logger.info(
            "consolidate unit=%d tick=%d — journal stored (%d chars)",
            unit_id, tick, len(summary),
        )
        return summary
