"""
schemas.py — Pydantic action models for DFHack command validation.
All LLM responses are validated against these schemas via response_schema enforcement.
"""
from __future__ import annotations
from typing import Literal, Optional, Union
from pydantic import BaseModel, Field


class SpeakAction(BaseModel):
    type: Literal["speak"]
    text: str = Field(description="The dialogue text spoken by the NPC")


class InitiateBrawlAction(BaseModel):
    type: Literal["initiate_brawl"]
    instigator_id: int
    target_id: int


class RequestMeetingAction(BaseModel):
    type: Literal["request_meeting"]
    requester_id: int


class PublicRantAction(BaseModel):
    type: Literal["public_rant"]
    unit_id: int
    topic: str


class FleeAction(BaseModel):
    type: Literal["flee"]
    unit_id: int


class ModifyMoodAction(BaseModel):
    type: Literal["modify_mood"]
    unit_id: int
    stress_delta: int = Field(description="Positive = more stress, negative = relief. Max abs 1000. Use when the conversation was genuinely upsetting or comforting.")


class OpinionDeltaAction(BaseModel):
    type: Literal["opinion_delta"]
    delta: int = Field(description="Change to how this NPC feels about the player. -10 very insulted, -3 annoyed, 0 neutral, +3 pleased, +10 genuinely moved. Use whenever the player said something meaningful.")
    reason: str = Field(description="Brief note on why (one short sentence) — used as a memory hook.")


class NoAction(BaseModel):
    type: Literal["none"]


AnyAction = Union[
    SpeakAction,
    InitiateBrawlAction,
    RequestMeetingAction,
    PublicRantAction,
    FleeAction,
    ModifyMoodAction,
    OpinionDeltaAction,
    NoAction,
]


class DwarfResponse(BaseModel):
    """Top-level schema enforced on every Gemini call."""
    dialogue: str = Field(description="The NPC's spoken response, 1-4 sentences max.")
    action: AnyAction = Field(description="Optional game action to execute alongside dialogue.")
    emotional_state: str = Field(description="One-word emotion: calm/angry/fearful/joyful/grieving/drunk/suspicious")
