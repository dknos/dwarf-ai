"""
llm_client.py — Gemini client with response_schema enforcement, sliding window,
and tenacity retry for 429 throttle.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Optional

import tenacity
from google import genai
from google.genai import types as genai_types
from google.api_core import exceptions as google_exceptions

from schemas import DwarfResponse

logger = logging.getLogger(__name__)

_MODEL = "gemini-3.1-flash-lite-preview"
_RESPONSE_SCHEMA = DwarfResponse.model_json_schema()
_TEXT_MODEL = "gemini-3.1-flash-lite-preview"

# Sliding window: keep last N turns in messages[]; older turns summarized.
_WINDOW_TURNS = 4


def _build_client() -> genai.Client:
    api_key = os.environ.get("GOOGLE_API_KEY") or _load_env_key()
    if not api_key:
        raise RuntimeError("GOOGLE_API_KEY not set. Add it to ~/.nemoclaw_env.")
    return genai.Client(api_key=api_key)


def _load_env_key() -> Optional[str]:
    env_path = os.path.expanduser("~/.nemoclaw_env")
    try:
        with open(env_path) as f:
            for line in f:
                if line.startswith("GOOGLE_API_KEY="):
                    return line.strip().split("=", 1)[1]
    except OSError:
        pass
    return None


_client: Optional[genai.Client] = None


def get_client() -> genai.Client:
    global _client
    if _client is None:
        _client = _build_client()
    return _client


@tenacity.retry(
    wait=tenacity.wait_exponential(multiplier=1, min=2, max=30),
    stop=tenacity.stop_after_attempt(5),
    retry=tenacity.retry_if_exception_type(google_exceptions.ResourceExhausted),
    before_sleep=lambda rs: logger.warning(
        "Gemini 429 — retrying in %.1fs (attempt %d/5)",
        rs.next_action.sleep,  # type: ignore[attr-defined]
        rs.attempt_number,
    ),
)
def complete(
    system_prompt: str,
    messages: list[dict],
    model: str = _MODEL,
) -> DwarfResponse:
    """
    Call Gemini with sliding-window conversation history.
    messages: list of {"role": "user"|"model", "text": str}
    Returns a validated DwarfResponse.
    """
    client = get_client()

    # Enforce sliding window
    if len(messages) > _WINDOW_TURNS * 2:
        overflow = messages[: -(  _WINDOW_TURNS * 2)]
        summary_text = "Earlier in this conversation: " + " | ".join(
            m["text"][:80] for m in overflow if m["role"] == "model"
        )
        messages = [{"role": "user", "text": summary_text}] + messages[-(  _WINDOW_TURNS * 2):]

    contents = []
    for m in messages:
        contents.append(
            genai_types.Content(
                role=m["role"],
                parts=[genai_types.Part(text=m["text"])],
            )
        )

    cfg = genai_types.GenerateContentConfig(
        system_instruction=system_prompt,
        response_mime_type="application/json",
        response_schema=_RESPONSE_SCHEMA,
        temperature=0.8,
        max_output_tokens=300,
    )

    resp = client.models.generate_content(
        model=model,
        contents=contents,
        config=cfg,
    )

    raw = resp.text or "{}"
    try:
        data = json.loads(raw)
        return DwarfResponse(**data)
    except Exception as exc:
        logger.error("Schema parse failed: %s | raw=%s", exc, raw[:200])
        return DwarfResponse(
            dialogue="...",
            action={"type": "none"},
            emotional_state="calm",
        )


@tenacity.retry(
    wait=tenacity.wait_exponential(multiplier=1, min=2, max=30),
    stop=tenacity.stop_after_attempt(5),
    retry=tenacity.retry_if_exception_type(google_exceptions.ResourceExhausted),
    before_sleep=lambda rs: logger.warning(
        "Gemini 429 (text) — retrying in %.1fs (attempt %d/5)",
        rs.next_action.sleep,  # type: ignore[attr-defined]
        rs.attempt_number,
    ),
)
def complete_text(
    system_prompt: str,
    user_message: str,
    model: str = _TEXT_MODEL,
) -> str:
    """
    Free-form text completion — no response_schema, returns plain string.
    Used for journal summarisation and other non-NPC tasks.

    Args:
        system_prompt: Instructions for the model.
        user_message:  The user-side content.
        model:         Gemini model name.

    Returns:
        The model's raw text response.
    """
    client = get_client()
    contents = [
        genai_types.Content(
            role="user",
            parts=[genai_types.Part(text=user_message)],
        )
    ]
    cfg = genai_types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.7,
        max_output_tokens=200,
    )
    resp = client.models.generate_content(
        model=model,
        contents=contents,
        config=cfg,
    )
    return (resp.text or "").strip()
