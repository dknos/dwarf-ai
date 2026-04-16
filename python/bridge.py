"""
bridge.py — File-watcher orchestrator for dwarf-ai.

Watches ipc/context/ for {uuid}.json files written by DFHack Lua.
Dispatches to context_router → context_engine → llm_client.
Writes ipc/responses/{uuid}.json.
Moves processed context files to ipc/processed/.

Phase 4: PressureEngine runs in background; fires spontaneous context requests.
Phase 5: DwarfPairingLoop runs in background; fires d2d context requests.
         d2d responses are written as d2d_{interaction_id}.json.
"""
from __future__ import annotations

import json
import logging
import os
import pathlib
import shutil
import time
from datetime import datetime, timezone
from typing import Optional

import yaml
from watchdog.observers.polling import PollingObserver as Observer
from watchdog.events import FileSystemEventHandler, FileCreatedEvent

from context_engine import build_system_prompt, build_spontaneous_prompt, build_d2d_prompt
from context_router import ContextRouter
from dwarf_pairing import DwarfPairingLoop
from legends_rag import LegendIndex
from llm_client import complete
from memory.episodic import EpisodicMemory
from memory.consolidator import SleepConsolidator
from memory.pressure import PressureEngine

logger = logging.getLogger(__name__)

# Known paths where DF exports legends.xml.  Tried in order at startup.
_LEGENDS_SEARCH_PATHS: list[str] = [
    # Convenience: user can drop a copy here
    "/home/nemoclaw/dwarf-ai/legends.xml",
    # DF save directory — legends exports live one level deep inside region dirs
    "/mnt/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/data/save",
]


def _find_legends_xml() -> Optional[str]:
    """Return the first legends.xml found in known locations, or None."""
    for base in _LEGENDS_SEARCH_PATHS:
        p = pathlib.Path(base)
        if p.is_file() and p.suffix == ".xml":
            return str(p)
        if p.is_dir():
            for child in sorted(p.iterdir()):
                candidate = child / "legends.xml"
                if candidate.is_file():
                    return str(candidate)
    return None


def _try_load_legends(cfg: dict) -> Optional[LegendIndex]:
    """
    Load an existing LegendIndex or build a new one from legends.xml.
    Returns None when no legends.xml is available.  Never raises.
    """
    chroma_dir = cfg.get("memory", {}).get("chroma_dir", "/home/nemoclaw/dwarf-ai/chroma")
    idx = LegendIndex(chroma_dir=chroma_dir)

    if idx.is_built():
        logger.info("LegendIndex: loaded existing index from %s", chroma_dir)
        return idx

    xml_path = _find_legends_xml()
    if xml_path is None:
        logger.info(
            "LegendIndex: no legends.xml found — world-history RAG disabled. "
            "Export from DF Legends mode to enable."
        )
        return None

    try:
        logger.info("LegendIndex: building from %s …", xml_path)
        idx.build(xml_path)
        logger.info("LegendIndex: build complete.")
        return idx
    except Exception as exc:
        logger.warning("LegendIndex: build failed (%s) — continuing without RAG.", exc)
        return None


def _load_config(path: str = "config.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def _atomic_write(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class ContextHandler(FileSystemEventHandler):
    def __init__(
        self,
        cfg: dict,
        router: ContextRouter,
        legends_rag: Optional[LegendIndex] = None,
    ):
        self._cfg = cfg
        self._router = router
        self._ipc = cfg["ipc"]
        # Optional world-history RAG index (Phase 7)
        self._legends_rag = legends_rag
        # Per-dwarf conversation history: {unit_id: [{"role":..,"text":..}]}
        self._histories: dict[int, list[dict]] = {}
        # Episodic memory store
        chroma_dir: str = cfg.get("memory", {}).get("chroma_dir", "/home/nemoclaw/dwarf-ai/chroma")
        self._episodic = EpisodicMemory(chroma_dir=chroma_dir)
        self._consolidator = SleepConsolidator(self._episodic)
        # Lasting per-NPC opinion of the player (persistent across bridge restarts)
        self._opinion_path = pathlib.Path(chroma_dir) / "opinions.json"
        self._opinions: dict[int, int] = self._load_opinions()

    def _load_opinions(self) -> dict[int, int]:
        try:
            if self._opinion_path.exists():
                with open(self._opinion_path, encoding="utf-8") as f:
                    raw = json.load(f)
                return {int(k): int(v) for k, v in raw.items()}
        except Exception as exc:
            logger.warning("Could not load opinions: %s", exc)
        return {}

    def _save_opinions(self) -> None:
        try:
            self._opinion_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._opinion_path.with_suffix(".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({str(k): v for k, v in self._opinions.items()}, f, indent=2)
            tmp.replace(self._opinion_path)
        except OSError as exc:
            logger.warning("Could not save opinions: %s", exc)

    def _get_opinion(self, unit_id: int) -> int:
        return self._opinions.get(unit_id, 0)

    def _apply_opinion_delta(self, unit_id: int, delta: int, reason: str) -> None:
        delta = max(-20, min(20, delta))
        new_score = max(-100, min(100, self._get_opinion(unit_id) + delta))
        self._opinions[unit_id] = new_score
        self._save_opinions()
        logger.info("opinion: unit=%s delta=%+d -> %+d (reason: %s)",
                    unit_id, delta, new_score, reason[:80])
        # Also persist the reason as a memory so it shapes future conversations
        try:
            self._episodic.add_event(
                unit_id=unit_id,
                event_text=f"My opinion of the player shifted ({delta:+d}): {reason}",
                emotional_weight=max(40, min(90, 30 + abs(delta) * 4)),
            )
        except Exception as exc:
            logger.warning("opinion memory add failed: %s", exc)

    @staticmethod
    def _opinion_to_text(score: int) -> str:
        if score >= 30:  return "This player has earned your deep trust and warmth. Speak to them as a valued friend."
        if score >= 10:  return "You like this player. They've been pleasant in past encounters."
        if score >= 3:   return "You have a mildly favorable impression of this player."
        if score <= -30: return "You strongly distrust or despise this player. Be guarded and terse, or openly hostile if your temperament allows."
        if score <= -10: return "You dislike this player. They have offended or unsettled you before."
        if score <= -3:  return "You have a slightly negative impression of this player."
        return ""  # neutral — no injection

    def on_created(self, event: FileCreatedEvent) -> None:
        if event.is_directory:
            return
        self._ingest(pathlib.Path(event.src_path))

    def on_modified(self, event) -> None:
        # PollingObserver on /mnt/c may fire modified instead of created
        if event.is_directory:
            return
        self._ingest(pathlib.Path(event.src_path))

    def _ingest(self, path: pathlib.Path) -> None:
        if path.suffix != ".json" or path.stem.startswith("."):
            return
        if not path.exists():
            return
        time.sleep(0.05)
        try:
            with open(path, encoding="utf-8") as f:
                ctx = json.load(f)
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Could not read context %s: %s", path.name, exc)
            return

        ctx["_context_file"] = str(path)
        ctx["_ts_received"] = time.time()
        self._router.submit(ctx, self._handle)

    def scan_existing(self, context_dir: str) -> None:
        """Pick up any context files written before the bridge started."""
        d = pathlib.Path(context_dir)
        if not d.exists():
            return
        for p in sorted(d.glob("*.json")):
            if not p.stem.startswith("."):
                logger.info("Picking up existing context file: %s", p.name)
                self._ingest(p)

    def _handle(self, ctx: dict) -> None:
        interaction_id = ctx.get("interaction_id", pathlib.Path(ctx["_context_file"]).stem)
        req_type = ctx.get("type", "interactive")

        if req_type == "memory_event":
            # Index event in episodic store — no LLM call needed
            unit_id = ctx.get("unit_id", 0)
            event_text = ctx.get("event_text", "")
            emotional_weight = int(ctx.get("emotional_weight", 30))
            tick = ctx.get("tick")
            if event_text:
                try:
                    self._episodic.add_event(
                        unit_id=unit_id,
                        event_text=event_text,
                        emotional_weight=emotional_weight,
                        tick=tick,
                    )
                except Exception as exc:
                    logger.error("episodic.add_event failed for unit=%s: %s", unit_id, exc)
            self._archive(ctx)
            return

        if req_type == "sleep_event":
            # Consolidate today's memories into a journal entry
            unit_id = ctx.get("unit_id", 0)
            try:
                self._consolidator.consolidate(unit_id=unit_id, ctx=ctx)
            except Exception as exc:
                logger.error("consolidation failed for unit=%s: %s", unit_id, exc)
            self._archive(ctx)
            return

        # --- Phase 5: d2d (dwarf-to-dwarf) ---------------------------------
        if req_type == "d2d":
            self._handle_d2d(ctx, interaction_id)
            self._archive(ctx)
            return

        # --- Phase 4: spontaneous pressure event ----------------------------
        if req_type == "spontaneous":
            self._handle_spontaneous(ctx, interaction_id)
            self._archive(ctx)
            return

        # --- Phase 6/7: fortress briefing (mayor screen) --------------------
        if req_type == "fortress_briefing":
            self._handle_fortress_briefing(ctx, interaction_id)
            self._archive(ctx)
            return

        # --- Default: interactive player conversation -----------------------
        unit_id = ctx.get("unit_id", 0)
        player_input = ctx.get("player_input", "")

        # Inject lasting opinion of player into context
        opinion = self._get_opinion(unit_id)
        ctx["player_opinion"] = opinion
        ctx["player_opinion_text"] = self._opinion_to_text(opinion)

        # Inject relevant memories into context before building the prompt
        try:
            relevant = self._episodic.query(unit_id, player_input, top_k=3)
            if relevant:
                existing = ctx.get("core_memories", [])
                ctx["core_memories"] = existing + relevant
        except Exception as exc:
            logger.warning("episodic.query failed for unit=%s: %s", unit_id, exc)

        # Build conversation history
        history = self._histories.get(unit_id, [])
        history.append({"role": "user", "text": player_input})

        system_prompt = build_system_prompt(ctx, legends_rag=self._legends_rag)

        try:
            response = complete(system_prompt=system_prompt, messages=history)
        except Exception as exc:
            logger.error("LLM call failed for %s: %s", interaction_id, exc)
            response = None

        # Append model reply to history
        if response:
            history.append({"role": "model", "text": response.dialogue})
        self._histories[unit_id] = history[-8:]  # keep last 4 turns (8 messages)

        # Persist this exchange to episodic memory so the NPC remembers it.
        if response:
            try:
                turn_text = f'The player said: "{player_input}" — I replied: "{response.dialogue}"'
                weight = 30
                emo = (response.emotional_state or "").lower()
                if emo in ("angry", "grieving", "fearful", "suspicious"):
                    weight = 60
                elif emo in ("joyful",):
                    weight = 50
                self._episodic.add_event(
                    unit_id=unit_id, event_text=turn_text, emotional_weight=weight
                )
            except Exception as exc:
                logger.warning("episodic.add_event (turn) failed for unit=%s: %s", unit_id, exc)

            # Apply opinion_delta if the model emitted one.
            act = response.action.model_dump() if response.action else {"type": "none"}
            if act.get("type") == "opinion_delta":
                delta  = int(act.get("delta", 0) or 0)
                reason = str(act.get("reason", ""))
                self._apply_opinion_delta(unit_id, delta, reason)

        # Write response file
        responses_dir = pathlib.Path(self._ipc["responses_dir"])
        out = {
            "interaction_id": interaction_id,
            "unit_id": unit_id,
            "type": req_type,
            "dialogue": response.dialogue if response else "*Urist glares at you silently.*",
            "action": response.action.model_dump() if response else {"type": "none"},
            "emotional_state": response.emotional_state if response else "calm",
            "timestamp": _now_iso(),
        }
        _atomic_write(responses_dir / f"{interaction_id}.json", out)
        logger.info("[%s] dialogue written for unit=%s opinion=%+d",
                    interaction_id[:8], unit_id, self._get_opinion(unit_id))

        self._archive(ctx)

    # ------------------------------------------------------------------
    # Phase 4: spontaneous pressure dispatch
    # ------------------------------------------------------------------

    def _handle_spontaneous(self, ctx: dict, interaction_id: str) -> None:
        """
        A dwarf's internal pressure has breached a threshold.
        Synthesise a monologue/outburst — no player_input exists.
        """
        unit_id = ctx.get("unit_id", 0)
        pressure_type = ctx.get("pressure_type", "frustration")
        pressure_level = float(ctx.get("pressure_level", 75.0))
        unit_name = ctx.get("unit_name", "Unknown")

        system_prompt = build_spontaneous_prompt(ctx)

        # Synthetic trigger message drives the LLM without real player input
        trigger_text = (
            f"[Internal pressure: {pressure_type} at {pressure_level:.0f}/100. "
            "The dwarf is overwhelmed and acts on impulse. "
            "Generate what they say or do aloud — 1-3 sentences.]"
        )
        messages = [{"role": "user", "text": trigger_text}]

        try:
            response = complete(system_prompt=system_prompt, messages=messages)
        except Exception as exc:
            logger.error("LLM spontaneous call failed for %s: %s", interaction_id, exc)
            response = None

        responses_dir = pathlib.Path(self._ipc["responses_dir"])
        out = {
            "interaction_id": interaction_id,
            "unit_id": unit_id,
            "unit_name": unit_name,
            "type": "spontaneous",
            "pressure_type": pressure_type,
            "dialogue": response.dialogue if response else f"*{unit_name} mutters darkly.*",
            "action": response.action.model_dump() if response else {"type": "none"},
            "emotional_state": response.emotional_state if response else "distressed",
            "timestamp": _now_iso(),
        }
        _atomic_write(responses_dir / f"{interaction_id}.json", out)
        logger.info(
            "[%s] spontaneous written for unit=%s pressure=%s",
            interaction_id[:8], unit_id, pressure_type,
        )

    # ------------------------------------------------------------------
    # Phase 5: d2d dispatch
    # ------------------------------------------------------------------

    def _handle_d2d(self, ctx: dict, interaction_id: str) -> None:
        """
        Two dwarves have a spontaneous conversation.
        One LLM call with a dual-character system prompt.
        Response written as d2d_{interaction_id}.json for eavesdrop_view.lua.
        """
        unit_a = ctx.get("unit_a") or {}
        unit_b = ctx.get("unit_b") or {}
        location = ctx.get("location", "unknown")
        pairing_reason = ctx.get("pairing_reason", "unknown")

        name_a = unit_a.get("name", "Dwarf A")
        name_b = unit_b.get("name", "Dwarf B")

        system_prompt = build_d2d_prompt(ctx)

        trigger_text = (
            f"[{name_a} and {name_b} are both in {location}. "
            f"Reason they are drawn together: {pairing_reason}. "
            f"Write 2-4 lines of dialogue, alternating between them. "
            f"Format: '{name_a}: ...' then '{name_b}: ...' etc.]"
        )
        messages = [{"role": "user", "text": trigger_text}]

        try:
            response = complete(system_prompt=system_prompt, messages=messages)
        except Exception as exc:
            logger.error("LLM d2d call failed for %s: %s", interaction_id, exc)
            response = None

        responses_dir = pathlib.Path(self._ipc["responses_dir"])
        out = {
            "interaction_id": interaction_id,
            "type": "d2d",
            "unit_a": {"unit_id": unit_a.get("unit_id", 0), "name": name_a},
            "unit_b": {"unit_id": unit_b.get("unit_id", 0), "name": name_b},
            "location": location,
            "pairing_reason": pairing_reason,
            "dialogue": (
                response.dialogue
                if response
                else f"*{name_a} and {name_b} exchange a silent glance.*"
            ),
            "action": response.action.model_dump() if response else {"type": "none"},
            "emotional_state": response.emotional_state if response else "neutral",
            "timestamp": _now_iso(),
        }
        # interaction_id already carries the d2d_ prefix (set by DwarfPairingLoop).
        # Writing as {interaction_id}.json avoids a double d2d_d2d_ prefix while
        # still matching eavesdrop_view.lua's glob for ^d2d_.
        _atomic_write(responses_dir / f"{interaction_id}.json", out)
        logger.info(
            "[%s] d2d written: %s <-> %s @ %s",
            interaction_id[:8], name_a, name_b, location,
        )

    # ------------------------------------------------------------------
    # Phase 6/7: fortress_briefing — mayor report screen
    # ------------------------------------------------------------------

    def _handle_fortress_briefing(self, ctx: dict, interaction_id: str) -> None:
        """
        The Lua mayor_briefing.lua has sent a fortress_briefing context.
        Build a specialised system prompt for the expedition leader persona,
        optionally enrich it with legends RAG world history, then dispatch
        to the LLM and write a standard response file.

        Expected extra ctx keys:
          overall_mood       : str  e.g. "content"
          unmet_needs        : list[str]
          bad_thoughts_count : int
          tick               : int
        """
        overall_mood       = ctx.get("overall_mood", "unknown")
        unmet_needs        = ctx.get("unmet_needs", [])
        bad_thoughts_count = int(ctx.get("bad_thoughts_count", 0))

        # Compose a directive that shapes the expedition-leader persona beyond
        # the base persona already baked into the Lua context fields.
        system_note = (
            "You are the expedition leader giving the overseer a formal briefing. "
            "Be concise, honest, and slightly grave. Mention specifics. "
            f"Overall fortress mood: {overall_mood}. "
        )
        if unmet_needs:
            system_note += f"Top unmet needs: {', '.join(unmet_needs[:3])}. "
        if bad_thoughts_count > 0:
            system_note += (
                f"{bad_thoughts_count} dwarves are suffering from distressing thoughts. "
            )
        ctx["system_note"] = system_note

        # Build the prompt with legends RAG if available
        system_prompt = build_system_prompt(ctx, legends_rag=self._legends_rag)

        # Single-turn briefing — no conversation history needed
        player_input = ctx.get("player_input", "Give me your report.")
        messages = [{"role": "user", "text": player_input}]

        try:
            response = complete(system_prompt=system_prompt, messages=messages)
        except Exception as exc:
            logger.error("LLM fortress_briefing failed for %s: %s", interaction_id, exc)
            response = None

        responses_dir = pathlib.Path(self._ipc["responses_dir"])
        out = {
            "interaction_id":     interaction_id,
            "unit_id":            ctx.get("unit_id", 0),
            "type":               "fortress_briefing",
            "overall_mood":       overall_mood,
            "unmet_needs":        unmet_needs,
            "bad_thoughts_count": bad_thoughts_count,
            "dialogue": (
                response.dialogue
                if response
                else "*The expedition leader shuffles the reports nervously.*"
            ),
            "action":         response.action.model_dump() if response else {"type": "none"},
            "emotional_state": response.emotional_state if response else "calm",
            "timestamp":       _now_iso(),
        }
        _atomic_write(responses_dir / f"{interaction_id}.json", out)
        logger.info(
            "[%s] fortress_briefing written (mood=%s, bad_thoughts=%d)",
            interaction_id[:8], overall_mood, bad_thoughts_count,
        )

    def _archive(self, ctx: dict) -> None:
        src = pathlib.Path(ctx["_context_file"])
        dst = pathlib.Path(self._ipc["processed_dir"]) / src.name
        try:
            shutil.move(str(src), dst)
        except OSError:
            pass


def run(config_path: str = "config.yaml") -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = _load_config(config_path)
    ipc = cfg["ipc"]

    for d in ipc.values():
        pathlib.Path(d).mkdir(parents=True, exist_ok=True)

    # --- Phase 4: start pressure engine in background ---
    pressure_dir = ipc.get("pressure_dir", "/home/nemoclaw/dwarf-ai/lua/ipc/pressure")
    context_dir = ipc["context_dir"]
    pressure_engine = PressureEngine(
        pressure_dir=pressure_dir,
        context_dir=context_dir,
    )
    pressure_engine.start()

    # --- Phase 5: start dwarf pairing loop in background ---
    pairing_loop = DwarfPairingLoop(
        pressure_dir=pressure_dir,
        context_dir=context_dir,
        responses_dir=ipc["responses_dir"],
    )
    pairing_loop.start()

    # --- Phase 7: try to load Legends RAG index ---
    legends_rag = _try_load_legends(cfg)

    router = ContextRouter(max_concurrent=cfg["llm"]["max_concurrent_llm_calls"])
    handler = ContextHandler(cfg, router, legends_rag=legends_rag)

    observer = Observer()
    observer.schedule(handler, ipc["context_dir"], recursive=False)
    observer.start()

    logger.info("dwarf-ai bridge watching %s", ipc["context_dir"])
    handler.scan_existing(ipc["context_dir"])
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    run()
