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
    """You physically attack the player right now. No IDs needed — you are the attacker, they are the target."""
    type: Literal["initiate_brawl"]
    intensity: Literal["shove", "strike", "kill"] = Field(default="strike", description="shove = push/warn, strike = punch/draw weapon, kill = lethal intent")


class RequestMeetingAction(BaseModel):
    type: Literal["request_meeting"]


class PublicRantAction(BaseModel):
    type: Literal["public_rant"]
    topic: str


class FleeAction(BaseModel):
    """You run away from the player in fear."""
    type: Literal["flee"]


class ModifyMoodAction(BaseModel):
    type: Literal["modify_mood"]
    stress_delta: int = Field(description="Positive = more stress, negative = relief. Max abs 1000. Use when the conversation was genuinely upsetting or comforting.")


class OpinionDeltaAction(BaseModel):
    type: Literal["opinion_delta"]
    delta: int = Field(description="Change to how this NPC feels about the player. -10 very insulted, -3 annoyed, 0 neutral, +3 pleased, +10 genuinely moved. Use whenever the player said something meaningful.")
    reason: str = Field(description="Brief note on why (one short sentence) — used as a memory hook.")


class CallGuardsAction(BaseModel):
    type: Literal["call_guards"]
    reason: str = Field(description="Why you're calling for help (crime witnessed, threat, etc.)")


class IssueThreatAction(BaseModel):
    type: Literal["issue_threat"]
    threat: str = Field(description="Exactly what you threatened to do if the player continues.")


class DemandPaymentAction(BaseModel):
    type: Literal["demand_payment"]
    amount: int = Field(description="Coins demanded, 1-10000")
    reason: str = Field(description="Why payment is owed — unpaid debt, bribe, ransom, tax")


class OfferQuestAction(BaseModel):
    type: Literal["offer_quest"]
    title: str = Field(description="Short quest title (5-10 words)")
    objective: str = Field(description="What the player needs to do")
    reward: str = Field(description="What the NPC offers in exchange")


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
    CallGuardsAction,
    IssueThreatAction,
    DemandPaymentAction,
    OfferQuestAction,
    NoAction,
]


class DwarfResponse(BaseModel):
    """Top-level schema enforced on every Gemini call."""
    dialogue: str = Field(description="The NPC's spoken response, 1-4 sentences max.")
    action: AnyAction = Field(description="Optional game action to execute alongside dialogue.")
    emotional_state: str = Field(description="One-word emotion: calm/angry/fearful/joyful/grieving/drunk/suspicious")
