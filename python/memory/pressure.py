"""
memory/pressure.py — Autonomous Pressure System (Phase 4)

PressureEngine runs in a background daemon thread, ticking every 1 real-time
second.  Each tick it reads snapshot files from ipc/pressure/ written by Lua,
accumulates per-dwarf pressure (frustration, loneliness, grief, excitement),
and fires spontaneous context requests when a pressure type crosses its
threshold.

Expected Lua snapshot format (ipc/pressure/{unit_id}_{ts}.json):
{
  "unit_id": 42,
  "unit_name": "Urist McBeard",
  "location": "tavern",
  "activity": "idle",
  "emotions": [{"type": "grief", "strength": 80}, ...],
  "facets": {"ANGER_PROPENSITY": 72, ...},
  "values": {"FAMILY": 85, ...},
  "relationships": [{"name": "Bomrek", "type": "friend", "strength": 60}],
  "hunger": 0,
  "thirst": 0,
  "fatigue": 0,
  "alcohol": 0
}
"""
from __future__ import annotations

import glob
import json
import logging
import pathlib
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Dict, Optional

logger = logging.getLogger(__name__)

# --- Pressure accumulation constants ---
TICK_INTERVAL_SEC = 1.0          # real-time seconds per tick

# Per emotion-type → which pressure bucket it fills
_EMOTION_TO_BUCKET: dict[str, str] = {
    "grief":      "grief",
    "sadness":    "grief",
    "mourning":   "grief",
    "anger":      "frustration",
    "rage":       "frustration",
    "frustration":"frustration",
    "loneliness": "loneliness",
    "boredom":    "loneliness",
    "joy":        "excitement",
    "elation":    "excitement",
    "excitement": "excitement",
    "enthusiasm": "excitement",
}

# Per bucket: base decay per tick and threshold to fire spontaneous event
_BUCKET_DECAY: dict[str, float] = {
    "frustration": 0.3,
    "loneliness":  0.2,
    "grief":       0.1,   # grief lingers longest
    "excitement":  0.5,
}

_BUCKET_THRESHOLD: dict[str, float] = {
    "frustration": 75.0,
    "loneliness":  70.0,
    "grief":       65.0,
    "excitement":  80.0,
}

# Minimum real-time seconds between spontaneous events for the same dwarf
# (to prevent spam).
_COOLDOWN_SEC = 60.0


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_write(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def _load_snapshot(path: pathlib.Path) -> Optional[dict]:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        logger.debug("Could not read pressure snapshot %s: %s", path.name, exc)
        return None


class _DwarfPressure:
    """Mutable pressure state for a single dwarf."""

    def __init__(self) -> None:
        self.buckets: dict[str, float] = {
            "frustration": 0.0,
            "loneliness":  0.0,
            "grief":       0.0,
            "excitement":  0.0,
        }
        self.last_snapshot: Optional[dict] = None
        self.last_event_ts: float = 0.0   # wall-clock time of last spontaneous fire

    def accumulate(self, snapshot: dict) -> None:
        """Absorb new emotion data from a Lua snapshot."""
        emotions = snapshot.get("emotions") or []
        for em in emotions:
            em_type = str(em.get("type", "")).lower()
            strength = float(em.get("strength", 0))
            bucket = _EMOTION_TO_BUCKET.get(em_type)
            if bucket:
                # Scale: emotion strength 0-100 → accumulate 0-2.0 points/tick
                self.buckets[bucket] = min(100.0, self.buckets[bucket] + (strength / 50.0))

        # Loneliness grows passively when idle
        if str(snapshot.get("activity", "")).lower() in ("idle", "socializing", "resting"):
            self.buckets["loneliness"] = min(100.0, self.buckets["loneliness"] + 0.4)

        self.last_snapshot = snapshot

    def decay(self) -> None:
        """Apply per-tick decay to all buckets."""
        for bucket, rate in _BUCKET_DECAY.items():
            self.buckets[bucket] = max(0.0, self.buckets[bucket] - rate)

    def check_thresholds(self) -> Optional[str]:
        """
        Return the bucket name that has breached its threshold, or None.
        Prioritises the highest overshoot; returns only one bucket per check.
        """
        now = time.time()
        if now - self.last_event_ts < _COOLDOWN_SEC:
            return None
        best_bucket: Optional[str] = None
        best_overshoot = 0.0
        for bucket, threshold in _BUCKET_THRESHOLD.items():
            overshoot = self.buckets[bucket] - threshold
            if overshoot > best_overshoot:
                best_overshoot = overshoot
                best_bucket = bucket
        return best_bucket

    def mark_fired(self) -> None:
        self.last_event_ts = time.time()

    def reset_bucket(self, bucket: str) -> None:
        self.buckets[bucket] = 0.0


class PressureEngine:
    """
    Background daemon that reads Lua pressure snapshots, accumulates per-dwarf
    pressure, and fires spontaneous context requests when thresholds breach.

    Usage:
        engine = PressureEngine(pressure_dir, context_dir)
        engine.start()
    """

    def __init__(self, pressure_dir: str, context_dir: str) -> None:
        self._pressure_dir = pathlib.Path(pressure_dir)
        self._context_dir = pathlib.Path(context_dir)
        self._lock = threading.Lock()
        self._state: Dict[int, _DwarfPressure] = {}   # unit_id → pressure
        self._thread: Optional[threading.Thread] = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the background tick thread as a daemon."""
        if self._thread and self._thread.is_alive():
            logger.warning("PressureEngine already running.")
            return
        self._thread = threading.Thread(
            target=self._loop, name="PressureEngine", daemon=True
        )
        self._thread.start()
        logger.info("PressureEngine started (pressure_dir=%s)", self._pressure_dir)

    def get_state(self, unit_id: int) -> Optional[dict]:
        """Thread-safe read of current pressure buckets for a dwarf."""
        with self._lock:
            dp = self._state.get(unit_id)
            if dp is None:
                return None
            return dict(dp.buckets)

    # ------------------------------------------------------------------
    # Internal loop
    # ------------------------------------------------------------------

    def _loop(self) -> None:
        while True:
            try:
                self._tick()
            except Exception as exc:
                logger.error("PressureEngine tick error: %s", exc, exc_info=True)
            time.sleep(TICK_INTERVAL_SEC)

    def _tick(self) -> None:
        snapshots = self._read_snapshots()

        with self._lock:
            # Accumulate fresh data
            for snap in snapshots:
                unit_id = snap.get("unit_id")
                if unit_id is None:
                    continue
                unit_id = int(unit_id)
                if unit_id not in self._state:
                    self._state[unit_id] = _DwarfPressure()
                self._state[unit_id].accumulate(snap)

            # Decay all tracked dwarves and fire thresholds
            to_fire: list[tuple[int, str, dict, float]] = []
            for unit_id, dp in self._state.items():
                dp.decay()
                breached = dp.check_thresholds()
                if breached and dp.last_snapshot:
                    # Capture level BEFORE reset so it reflects the actual value
                    level = round(dp.buckets.get(breached, 0.0), 1)
                    to_fire.append((unit_id, breached, dp.last_snapshot, level))
                    dp.mark_fired()
                    dp.reset_bucket(breached)

        # Write context requests outside the lock
        for unit_id, bucket, snapshot, level in to_fire:
            self._fire_spontaneous(unit_id, bucket, snapshot, level)

    def _read_snapshots(self) -> list[dict]:
        """
        Read all .json files in the pressure dir.
        These are written by Lua (one file per unit per update).
        Returns a list of parsed snapshot dicts.
        """
        snapshots: list[dict] = []
        if not self._pressure_dir.exists():
            return snapshots
        for path in self._pressure_dir.glob("*.json"):
            if path.name.startswith("."):
                continue
            snap = _load_snapshot(path)
            if snap:
                snapshots.append(snap)
        return snapshots

    def _fire_spontaneous(
        self, unit_id: int, pressure_type: str, snapshot: dict, level: float
    ) -> None:
        """Write a spontaneous context request to ipc/context/."""
        interaction_id = f"spont_{unit_id}_{uuid.uuid4().hex[:8]}"
        ctx: dict = {
            "interaction_id": interaction_id,
            "type": "spontaneous",
            "unit_id": unit_id,
            "unit_name": snapshot.get("unit_name", "Unknown"),
            "pressure_type": pressure_type,
            "pressure_level": level,
            # Include full dwarf state for the system prompt builder
            "npc_name":       snapshot.get("unit_name", "Unknown"),
            "npc_race":       snapshot.get("npc_race", "Dwarf"),
            "npc_profession": snapshot.get("npc_profession", "commoner"),
            "facets":         snapshot.get("facets", {}),
            "values":         snapshot.get("values", {}),
            "emotions":       snapshot.get("emotions", []),
            "wounds":         snapshot.get("wounds", []),
            "hunger":         snapshot.get("hunger", 0),
            "thirst":         snapshot.get("thirst", 0),
            "fatigue":        snapshot.get("fatigue", 0),
            "alcohol":        snapshot.get("alcohol", 0),
            "location":       snapshot.get("location", "unknown"),
            "relationships":  snapshot.get("relationships", []),
            "timestamp":      _now_iso(),
        }
        out_path = self._context_dir / f"{interaction_id}.json"
        _atomic_write(out_path, ctx)
        logger.info(
            "[pressure] Spontaneous event: unit=%d bucket=%s level=%.1f → %s",
            unit_id, pressure_type, ctx["pressure_level"], interaction_id,
        )

    def _get_pressure_level(self, unit_id: int, bucket: str) -> float:
        """Return current bucket value — called before reset so still has fired value."""
        with self._lock:
            dp = self._state.get(unit_id)
            if dp is None:
                return 0.0
            return round(dp.buckets.get(bucket, 0.0), 1)
