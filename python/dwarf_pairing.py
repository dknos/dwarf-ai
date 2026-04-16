"""
dwarf_pairing.py — Dwarf-to-Dwarf Spontaneous Interaction System (Phase 5)

Every 10 seconds, scans the active roster from pressure snapshots, finds two
idle dwarves with a meaningful social connection (shared grief, conflicting
values, faction rivalry), and fires a d2d context request for the LLM to
generate their dialogue.

Pairing priority:
  1. shared grief       — both dwarves have grief > 50 with overlapping loss
  2. conflicting values — value scores differ by ≥ 40 on the same key
  3. faction rivalry    — relationship type is "rival" or "enemy"

A dwarf already in an active interaction (has a pending d2d file in
ipc/context/ or ipc/responses/) is excluded from pairing.
"""
from __future__ import annotations

import glob
import json
import logging
import pathlib
import random
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger(__name__)

# Seconds between pairing sweeps
PAIRING_INTERVAL_SEC = 10.0

# Minimum grief strength to qualify as "shared grief"
GRIEF_THRESHOLD = 50

# Minimum value divergence to qualify as "conflicting values"
VALUE_CONFLICT_DELTA = 40

# Emotion types that count toward grief bucket for pairing
_GRIEF_EMOTIONS = frozenset({"grief", "sadness", "mourning", "anguish"})


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_write(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def _grief_level(snapshot: dict) -> float:
    """Return the highest grief-emotion strength for a snapshot."""
    best = 0.0
    for em in (snapshot.get("emotions") or []):
        if str(em.get("type", "")).lower() in _GRIEF_EMOTIONS:
            best = max(best, float(em.get("strength", 0)))
    return best


def _has_conflicting_values(snap_a: dict, snap_b: dict) -> Optional[str]:
    """
    Return the value key that conflicts most, or None.
    A conflict means the two dwarves score >= VALUE_CONFLICT_DELTA apart.
    """
    vals_a = snap_a.get("values") or {}
    vals_b = snap_b.get("values") or {}
    all_keys = set(vals_a) | set(vals_b)
    best_key: Optional[str] = None
    best_delta = 0
    for k in all_keys:
        va = float(vals_a.get(k, 50))
        vb = float(vals_b.get(k, 50))
        delta = abs(va - vb)
        if delta >= VALUE_CONFLICT_DELTA and delta > best_delta:
            best_delta = delta
            best_key = k
    return best_key


def _has_faction_rivalry(snap_a: dict, snap_b: dict) -> bool:
    """True if either dwarf lists the other as rival/enemy in relationships."""
    name_b = str(snap_b.get("unit_name", "")).lower()
    name_a = str(snap_a.get("unit_name", "")).lower()
    for rel in (snap_a.get("relationships") or []):
        if (
            str(rel.get("name", "")).lower() == name_b
            and str(rel.get("type", "")).lower() in ("rival", "enemy", "nemesis")
        ):
            return True
    for rel in (snap_b.get("relationships") or []):
        if (
            str(rel.get("name", "")).lower() == name_a
            and str(rel.get("type", "")).lower() in ("rival", "enemy", "nemesis")
        ):
            return True
    return False


def _score_pair(snap_a: dict, snap_b: dict) -> tuple[int, str]:
    """
    Return (priority_score, reason) for pairing snap_a and snap_b.
    Higher score = higher priority.  0 = not eligible.
    """
    grief_a = _grief_level(snap_a)
    grief_b = _grief_level(snap_b)
    if grief_a >= GRIEF_THRESHOLD and grief_b >= GRIEF_THRESHOLD:
        return (3, "shared_grief")

    if _has_faction_rivalry(snap_a, snap_b):
        return (2, "faction_rivalry")

    conflict_key = _has_conflicting_values(snap_a, snap_b)
    if conflict_key:
        return (1, f"value_conflict:{conflict_key}")

    return (0, "none")


def _lean_profile(snapshot: dict) -> dict:
    """
    Build the 'lean profile' for one dwarf — the minimal context bundle
    sent to the LLM for d2d prompts.
    """
    return {
        "unit_id":      snapshot.get("unit_id", 0),
        "name":         snapshot.get("unit_name", "Unknown"),
        "profession":   snapshot.get("npc_profession", "commoner"),
        "facets":       snapshot.get("facets", {}),
        "values":       snapshot.get("values", {}),
        "emotions":     snapshot.get("emotions", []),
        "hunger":       snapshot.get("hunger", 0),
        "thirst":       snapshot.get("thirst", 0),
        "fatigue":      snapshot.get("fatigue", 0),
        "alcohol":      snapshot.get("alcohol", 0),
        "relationships": snapshot.get("relationships", []),
    }


class DwarfPairingLoop:
    """
    Background daemon that periodically pairs dwarves for spontaneous d2d
    interaction.

    Usage:
        loop = DwarfPairingLoop(pressure_dir, context_dir, responses_dir)
        loop.start()
    """

    def __init__(
        self,
        pressure_dir: str,
        context_dir: str,
        responses_dir: str,
    ) -> None:
        self._pressure_dir = pathlib.Path(pressure_dir)
        self._context_dir = pathlib.Path(context_dir)
        self._responses_dir = pathlib.Path(responses_dir)
        self._lock = threading.Lock()
        # unit_ids currently participating in an active d2d interaction
        self._active_units: set[int] = set()
        self._thread: Optional[threading.Thread] = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the background pairing thread as a daemon."""
        if self._thread and self._thread.is_alive():
            logger.warning("DwarfPairingLoop already running.")
            return
        self._thread = threading.Thread(
            target=self._loop, name="DwarfPairingLoop", daemon=True
        )
        self._thread.start()
        logger.info("DwarfPairingLoop started (interval=%ds)", PAIRING_INTERVAL_SEC)

    # ------------------------------------------------------------------
    # Internal loop
    # ------------------------------------------------------------------

    def _loop(self) -> None:
        while True:
            try:
                self._sweep()
            except Exception as exc:
                logger.error("DwarfPairingLoop sweep error: %s", exc, exc_info=True)
            time.sleep(PAIRING_INTERVAL_SEC)

    def _sweep(self) -> None:
        # Refresh active_units from in-flight files
        self._refresh_active_units()

        # Load snapshots for all dwarves currently in pressure dir
        snapshots = self._load_roster()
        if len(snapshots) < 2:
            return

        # Exclude dwarves already in an active interaction
        with self._lock:
            active = set(self._active_units)
        candidates = [
            s for s in snapshots
            if int(s.get("unit_id", -1)) not in active
        ]
        if len(candidates) < 2:
            return

        # Find the best eligible pair
        best_score = 0
        best_reason = "none"
        best_pair: Optional[tuple[dict, dict]] = None

        # Shuffle to prevent always pairing the same first two
        shuffled = list(candidates)
        random.shuffle(shuffled)

        for i in range(len(shuffled)):
            for j in range(i + 1, len(shuffled)):
                score, reason = _score_pair(shuffled[i], shuffled[j])
                if score > best_score:
                    best_score = score
                    best_reason = reason
                    best_pair = (shuffled[i], shuffled[j])

        if best_pair is None or best_score == 0:
            return

        snap_a, snap_b = best_pair
        self._fire_d2d(snap_a, snap_b, best_reason)

    def _refresh_active_units(self) -> None:
        """
        Scan context/ and responses/ for d2d_* files to rebuild the set of
        dwarves currently mid-interaction.
        """
        active: set[int] = set()
        for search_dir in (self._context_dir, self._responses_dir):
            if not search_dir.exists():
                continue
            for p in search_dir.glob("d2d_*.json"):
                data = self._safe_read(p)
                if data:
                    ua = data.get("unit_a") or {}
                    ub = data.get("unit_b") or {}
                    uid_a = ua.get("unit_id")
                    uid_b = ub.get("unit_id")
                    if uid_a is not None:
                        active.add(int(uid_a))
                    if uid_b is not None:
                        active.add(int(uid_b))
        with self._lock:
            self._active_units = active

    def _load_roster(self) -> list[dict]:
        """Read all pressure snapshot files and return a list of snapshots."""
        roster: list[dict] = []
        if not self._pressure_dir.exists():
            return roster
        for p in self._pressure_dir.glob("*.json"):
            if p.name.startswith("."):
                continue
            data = self._safe_read(p)
            if data and data.get("unit_id") is not None:
                roster.append(data)
        return roster

    def _fire_d2d(self, snap_a: dict, snap_b: dict, reason: str) -> None:
        """Write a d2d context request to ipc/context/."""
        interaction_id = f"d2d_{uuid.uuid4().hex[:12]}"

        # Best-effort location: prefer shared location, else A's
        loc_a = str(snap_a.get("location", "unknown"))
        loc_b = str(snap_b.get("location", "unknown"))
        location = loc_a if loc_a == loc_b or loc_b == "unknown" else loc_a

        ctx: dict = {
            "interaction_id": interaction_id,
            "type": "d2d",
            "unit_a": _lean_profile(snap_a),
            "unit_b": _lean_profile(snap_b),
            "pairing_reason": reason,
            "location": location,
            "timestamp": _now_iso(),
        }
        out_path = self._context_dir / f"{interaction_id}.json"
        _atomic_write(out_path, ctx)

        # Mark both as active immediately to prevent double-pairing before
        # the file watcher picks this up.
        uid_a = int(snap_a.get("unit_id", -1))
        uid_b = int(snap_b.get("unit_id", -1))
        with self._lock:
            self._active_units.add(uid_a)
            self._active_units.add(uid_b)

        logger.info(
            "[pairing] d2d fired: %s ↔ %s reason=%s → %s",
            snap_a.get("unit_name"), snap_b.get("unit_name"),
            reason, interaction_id,
        )

    @staticmethod
    def _safe_read(path: pathlib.Path) -> Optional[dict]:
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return None
