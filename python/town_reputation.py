"""
town_reputation.py — persistent per-site player reputation tracker.

Every hostile NPC reaction (initiate_brawl / call_guards / demand_payment /
flee) adds notoriety to the current site's reputation score. Every
friendly interaction (opinion_delta > 0) slowly reduces it.

The score is injected into every NPC's system prompt so the entire town
gradually becomes wary, hostile, or welcoming based on the player's
behavior — not just the one NPC they're talking to.
"""
from __future__ import annotations

import json
import logging
import pathlib
import threading

logger = logging.getLogger(__name__)


class TownReputation:
    """
    Thread-safe persistent store for town-level notoriety.

    Score interpretation (abs value):
      0-5    unknown / unremarkable
      6-15   noticed — NPCs gossip, guards watch
      16-40  notorious — merchants raise prices, some refuse
      41+    hated — guards pre-alert, merchants close shop, NPCs hostile on sight

    Sign: positive = hero/benefactor, negative = criminal/menace.
    """

    def __init__(self, persist_path: str) -> None:
        self._path = pathlib.Path(persist_path)
        self._lock = threading.Lock()
        self._scores: dict[str, int] = self._load()

    def _load(self) -> dict[str, int]:
        try:
            if self._path.exists():
                with open(self._path, encoding="utf-8") as f:
                    raw = json.load(f)
                return {str(k): int(v) for k, v in raw.items()}
        except Exception as exc:
            logger.warning("Could not load town reputation: %s", exc)
        return {}

    def _save(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self._scores, f, indent=2)
            tmp.replace(self._path)
        except OSError as exc:
            logger.warning("Could not save town reputation: %s", exc)

    def get(self, site: str) -> int:
        with self._lock:
            return self._scores.get(site or "unknown", 0)

    def delta(self, site: str, change: int, reason: str = "") -> int:
        """Apply delta, return new score."""
        site = site or "unknown"
        with self._lock:
            new = max(-200, min(200, self._scores.get(site, 0) + change))
            self._scores[site] = new
            self._save()
        logger.info(
            "town_rep: %s %+d -> %+d (%s)",
            site, change, new, reason[:60],
        )
        return new

    @staticmethod
    def to_text(score: int) -> str:
        """Return a declarative sentence suitable for prompt injection."""
        a = abs(score)
        if score <= -41:
            return ("The player is a known murderer and threat in this town. "
                    "You have heard stories of their crimes. Guards are on alert. "
                    "You should be openly fearful or hostile.")
        if score <= -16:
            return ("The player is notorious in this town for violence or theft. "
                    "You are wary. Speak guardedly, and consider calling the guards "
                    "if they do anything suspicious.")
        if score <= -6:
            return ("You've heard the player has caused trouble here. You are cautious "
                    "but not yet alarmed.")
        if score >= 41:
            return ("The player is a renowned hero of this town. You greet them warmly.")
        if score >= 16:
            return ("The player is well-liked here; they have helped people you know.")
        if score >= 6:
            return ("You've heard good things about the player.")
        return ""

    # Convenience: map action type → reputation delta
    ACTION_DELTA: dict[str, int] = {
        "initiate_brawl":  -8,
        "call_guards":     -3,
        "issue_threat":    -2,
        "demand_payment":  -2,
        "flee":            -1,   # panic spreads
        "offer_quest":      0,
        "opinion_delta":   None,  # handled per-NPC instead
        "modify_mood":     None,
    }

    def apply_action(self, site: str, action_type: str, reason: str = "") -> int:
        d = self.ACTION_DELTA.get(action_type)
        if d is None or d == 0:
            return self.get(site)
        return self.delta(site, d, reason)
