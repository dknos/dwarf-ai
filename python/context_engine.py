"""
context_engine.py — Builds declarative system prompts from raw game state JSON.
All simulation math lives here. The LLM receives plain English, never raw integers.
"""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    from legends_rag import LegendIndex

logger = logging.getLogger(__name__)

# Facet thresholds → declarative injections
_FACET_RULES: list[tuple[str, int, str, bool]] = [
    # (facet_key, threshold, injection, above_threshold)
    ("ANGER_PROPENSITY",   70, "You are quick to anger. Keep sentences short and hostile.", True),
    ("ANGER_PROPENSITY",   20, "You are remarkably calm and slow to anger.", False),
    ("CHEER_PROPENSITY",   70, "You are naturally optimistic. You deflect bad news.", True),
    ("COWARDICE",          70, "You are terrified. You want to end this conversation and run away.", True),
    ("MARTIAL_PROWESS",    60, "You are proud of your combat record. Boast of battle when relevant.", True),
    ("ART_INCLINED",       60, "You dwell on craftsmanship and notice the quality of objects around you.", True),
    ("GREGARIOUSNESS",     70, "You are very social. You enjoy conversation and are talkative.", True),
    ("GREGARIOUSNESS",     20, "You are a loner. You want this conversation to end quickly.", False),
    ("ALTRUISM",           70, "You genuinely care about others' well-being.", True),
    ("GREED",              70, "You are greedy. You always think about what you can gain.", True),
    ("SUSPICIOUS",         70, "You are deeply suspicious of strangers. You give short, guarded answers.", True),
]

_VALUE_RULES: list[tuple[str, int, str]] = [
    ("TRADITION",      70, "You deeply respect tradition and the old ways."),
    ("MARTIAL_PROWESS",70, "You value strength and martial skill above all."),
    ("CRAFTSMANSHIP",  70, "You hold the quality of craft as sacred."),
    ("FAMILY",         70, "Your family means everything to you."),
    ("LAW",            70, "You believe firmly in law and justice."),
    ("WEALTH",         60, "You value wealth and material success."),
    ("NATURE",         70, "You have a deep love of the natural world."),
]


def build_system_prompt(
    ctx: dict,
    legends_rag: "Optional[LegendIndex]" = None,
) -> str:
    """
    Build a complete system prompt from the serialized game state context dict.

    Block ordering for Gemini prompt-cache efficiency:
      STATIC (rarely changes between turns for the same NPC):
        1. Persona header
        2. Personality facets
        3. Values
        4. Core memories
        5. World history (legends RAG) — semi-stable once built
      VOLATILE (changes every call):
        6. Physical state
        7. Current emotions
        8. Surroundings (room_description)
        9. Who you are speaking to (interlocutor_description)
       10. System note (replan / injected directive)
       11. Closing instruction

    Args:
        ctx: Serialised game-state dict.  Keys: npc_name, npc_race,
             npc_profession, facets, values, emotions, wounds, hunger, thirst,
             fatigue, alcohol, room_description, interlocutor_description,
             core_memories, system_note, player_input.
        legends_rag: Optional LegendIndex instance.  When provided and
                     is_built() is True the engine queries world-history
                     passages relevant to the current speaker + player input.
    """
    lines: list[str] = []

    name = ctx.get("npc_name", "Unknown")
    race = ctx.get("npc_race", "Dwarf")
    prof = ctx.get("npc_profession", "Commoner")

    # -----------------------------------------------------------------------
    # STATIC BLOCKS
    # -----------------------------------------------------------------------

    # 1. Persona header
    lines.append(f"You are {name}, a {race} {prof} in the world of Dwarf Fortress.")
    lines.append("Respond in character. Keep your reply to 1-4 sentences.")
    lines.append("")

    # 2. Personality facets — Lua's json encodes empty tables as [], coerce to {}
    facets = ctx.get("facets", {}) or {}
    if isinstance(facets, list):
        facets = {}
    facet_lines = []
    for key, threshold, text, above in _FACET_RULES:
        val = facets.get(key, 50)
        if (above and val >= threshold) or (not above and val <= threshold):
            facet_lines.append(text)
    if facet_lines:
        lines.append("## Personality")
        lines.extend(facet_lines)
        lines.append("")

    # 3. Values — same list/dict coercion
    values = ctx.get("values", {}) or {}
    if isinstance(values, list):
        values = {}
    value_lines = []
    for key, threshold, text in _VALUE_RULES:
        if values.get(key, 0) >= threshold:
            value_lines.append(text)
    if value_lines:
        lines.append("## Values")
        lines.extend(value_lines)
        lines.append("")

    # 4. Core memories (stable biographical facts — rarely changes per NPC)
    core_memories = ctx.get("core_memories", [])
    if core_memories:
        lines.append("## Important Memories")
        for m in core_memories:
            lines.append(f"- {m}")
        lines.append("")

    # 5. World history (legends RAG) — semi-stable, injected before volatile state
    if legends_rag is not None:
        try:
            if legends_rag.is_built():
                speaker   = ctx.get("npc_name", "Unknown")
                player_in = ctx.get("player_input", "")
                query_text = f"{speaker}: {player_in}" if player_in else speaker
                passages  = legends_rag.query(query_text, top_k=5)
                if passages:
                    lines.append("## World History Known to This Region")
                    for passage in passages:
                        lines.append(f"- {passage}")
                    lines.append("")
        except Exception as exc:
            logger.warning("legends_rag query failed: %s", exc)

    # -----------------------------------------------------------------------
    # VOLATILE BLOCKS
    # -----------------------------------------------------------------------

    # 6. Physical state
    phys_lines = []
    wounds = ctx.get("wounds", [])
    for w in wounds:
        phys_lines.append(
            f"You have a {w.get('severity', 'minor')} wound on your {w.get('body_part', 'body')}."
        )
        if w.get("missing"):
            phys_lines.append(f"Your {w.get('body_part', 'limb')} is missing.")
        if w.get("bleeding"):
            phys_lines.append("You are bleeding. Express severe physical pain.")

    alcohol = ctx.get("alcohol", 0)
    if alcohol >= 3:
        phys_lines.append("You are heavily intoxicated. Slur your words and lose focus easily.")
    elif alcohol >= 1:
        phys_lines.append("You have been drinking. You are a bit loose and jovial.")

    hunger  = ctx.get("hunger",  0)
    thirst  = ctx.get("thirst",  0)
    fatigue = ctx.get("fatigue", 0)
    if hunger > 75000:
        phys_lines.append("You are extremely hungry. You find it hard to concentrate.")
    if thirst > 50000:
        phys_lines.append("You are desperately thirsty.")
    if fatigue > 60000:
        phys_lines.append("You are exhausted. You speak slowly and make short replies.")

    if phys_lines:
        lines.append("## Physical State")
        lines.extend(phys_lines)
        lines.append("")

    # 7. Recent emotions
    emotions = ctx.get("emotions", [])
    if emotions:
        lines.append("## Current Emotions")
        for e in emotions[:3]:
            lines.append(f"You feel {e.get('type', 'something')} — {e.get('thought', '')}.")
        lines.append("")

    # 8. Room / spatial context  (from world_state.lua)
    room = ctx.get("room_description", "")
    if room:
        lines.append("## Surroundings")
        lines.append(room)
        lines.append("")

    # 9. Theory of You — who the player character is  (from world_state.lua)
    interlocutor = ctx.get("interlocutor_description", "")
    opinion_text = ctx.get("player_opinion_text", "")
    if interlocutor or opinion_text:
        lines.append("## Who You Are Speaking To")
        if interlocutor:
            lines.append(interlocutor)
        if opinion_text:
            lines.append(opinion_text)
        lines.append("")

    # 10. System note — injected by action_executor for replan contexts,
    #     or by orchestration logic for special directives.
    system_note = ctx.get("system_note", "")
    if system_note:
        lines.append("## Situation")
        lines.append(system_note)
        lines.append("")

    # 11. Closing instruction + action guidance
    lines.append("Respond only as this character. Do not break character or mention game mechanics.")
    lines.append("")
    lines.append("## Action Guidance — pick the action that matches what you would actually DO")
    lines.append("Your reply always carries one structured action. This is not decoration — it triggers real game effects. Pick the one that matches your character's intent, not a default.")
    lines.append("")
    lines.append("If the player is **robbing, threatening, or physically menacing** you:")
    lines.append("  - If you are armed/brave/angry: `initiate_brawl` (you attack them).")
    lines.append("  - If you are a coward or outmatched: `flee` or `call_guards`.")
    lines.append("  - Always at minimum: `issue_threat` if you've warned them verbally.")
    lines.append("If the player **owes you money or made a deal they broke**: `demand_payment` with the amount.")
    lines.append("If the player needs **help and you'd assign them a task**: `offer_quest` with title/objective/reward.")
    lines.append("If the player **insulted or unsettled you**: `opinion_delta` -3 to -10, and consider `modify_mood` stress_delta +100 to +500.")
    lines.append("If the player was **kind, helpful, or moved you**: `opinion_delta` +3 to +10.")
    lines.append("For routine or unremarkable exchanges: `opinion_delta` with delta near 0 (rarely `none`), so relationships accumulate.")
    lines.append("")
    lines.append("**Do not say you will do something and then pick `none`.** If you said you'd fight, return `initiate_brawl`. If you said you'd call the guards, return `call_guards`. Your words and your action must match.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Phase 4: Spontaneous pressure prompt
# ---------------------------------------------------------------------------

_PRESSURE_FLAVOUR: dict[str, str] = {
    "frustration": (
        "You have been building up intense frustration. You are not in control. "
        "You snap, mutter, or burst out — something must be said or done."
    ),
    "loneliness": (
        "You feel profoundly alone. The silence weighs on you. "
        "You find yourself speaking aloud even with no one to hear."
    ),
    "grief": (
        "A wave of grief overtakes you. You cannot hold it back. "
        "Tears, a whispered name, a broken sentence — let it out."
    ),
    "excitement": (
        "You are overflowing with excitement. You cannot keep quiet. "
        "You must announce this, share it, make the world know."
    ),
}


def build_spontaneous_prompt(ctx: dict) -> str:
    """
    Build a system prompt for a spontaneous pressure-driven monologue.
    Re-uses build_system_prompt for personality/state, then injects
    the pressure flavour text.
    """
    base = build_system_prompt(ctx)
    pressure_type = ctx.get("pressure_type", "frustration")
    flavour = _PRESSURE_FLAVOUR.get(pressure_type, _PRESSURE_FLAVOUR["frustration"])

    extra: list[str] = ["", "## Pressure Trigger", flavour, ""]

    location = ctx.get("location")
    if location and location != "unknown":
        extra += [f"You are currently in: {location}.", ""]

    relationships = ctx.get("relationships", [])
    if relationships:
        extra.append("## People On Your Mind")
        for rel in relationships[:3]:
            name = rel.get("name", "someone")
            rel_type = rel.get("type", "acquaintance")
            extra.append(f"- {name} ({rel_type})")
        extra.append("")

    extra.append(
        "Express this impulse in 1-3 sentences, entirely in character. "
        "Do not address the player; this is an internal outburst."
    )
    return base + "\n".join(extra)


# ---------------------------------------------------------------------------
# Phase 5: Dwarf-to-dwarf prompt
# ---------------------------------------------------------------------------

def _build_side_profile(profile: dict, label: str) -> list[str]:
    """Render one dwarf's personality profile for a d2d system prompt."""
    lines: list[str] = []
    name = profile.get("name", label)
    prof = profile.get("profession", "commoner")
    lines.append(f"### {name} ({prof})")

    facets = profile.get("facets", {})
    facet_lines: list[str] = []
    for key, threshold, text, above in _FACET_RULES:
        val = facets.get(key, 50)
        if (above and val >= threshold) or (not above and val <= threshold):
            facet_lines.append(text)
    if facet_lines:
        lines.append("Personality: " + " ".join(facet_lines))

    values = profile.get("values", {})
    value_lines: list[str] = []
    for key, threshold, text in _VALUE_RULES:
        if values.get(key, 0) >= threshold:
            value_lines.append(text)
    if value_lines:
        lines.append("Values: " + " ".join(value_lines))

    emotions = profile.get("emotions", [])
    if emotions:
        top = emotions[:2]
        em_str = "; ".join(
            f"{e.get('type', '?')} ({e.get('thought', '')})" for e in top
        )
        lines.append(f"Current emotions: {em_str}")

    alcohol = profile.get("alcohol", 0)
    if alcohol >= 3:
        lines.append("Is heavily intoxicated.")
    elif alcohol >= 1:
        lines.append("Has been drinking.")

    return lines


def build_d2d_prompt(ctx: dict) -> str:
    """
    Build a system prompt for a dwarf-to-dwarf spontaneous conversation.
    The LLM writes dialogue for both characters.
    """
    unit_a = ctx.get("unit_a") or {}
    unit_b = ctx.get("unit_b") or {}
    location = ctx.get("location", "somewhere in the fortress")
    reason = ctx.get("pairing_reason", "unknown")

    name_a = unit_a.get("name", "Dwarf A")
    name_b = unit_b.get("name", "Dwarf B")

    lines: list[str] = [
        "You are a narrator writing overheard dwarf dialogue in the world of Dwarf Fortress.",
        (
            f"Two dwarves — {name_a} and {name_b} — are having a spontaneous "
            f"conversation in {location}."
        ),
        f"What brought them together: {reason}.",
        "",
        "## Characters",
    ]
    lines.extend(_build_side_profile(unit_a, "Dwarf A"))
    lines.append("")
    lines.extend(_build_side_profile(unit_b, "Dwarf B"))
    lines += [
        "",
        "## Instructions",
        f"Write 2-4 lines of alternating dialogue between {name_a} and {name_b}.",
        f"Format each line as: '{name_a}: [line]' or '{name_b}: [line]'.",
        "Stay in character for both dwarves based on their personalities and the reason they met.",
        "Do not add stage directions or narration — only dialogue lines.",
        "Do not mention game mechanics.",
    ]
    return "\n".join(lines)
