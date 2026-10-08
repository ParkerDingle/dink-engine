"""Model input contract. Must match game/src/engine/features.ts exactly (tests/test_features.py checks this).

Engine coordinates: x is 0..20 across the court, y is 0..44 along it, net at y = 22.
Team 0 plays on y > 22. Players: 0 = team 0 left, 1 = team 0 right, 2 = team 1 left, 3 = team 1 right.
Every feature is from the hitter's point of view: x is feet to the hitter's right of the center line,
d is feet from the net.
"""
from __future__ import annotations

FEATURE_VERSION = "dink-features-v1"
SHOT_TYPES = ["dink", "drop", "drive", "speedup", "lob", "putaway"]
FEATURE_NAMES = [
    "hit_x", "hit_d", "hit_h", "in_speed", "shot_no",
    "partner_x", "partner_d", "oppA_x", "oppA_d", "oppB_x", "oppB_d",
    "opp_up", "my_up",
    *[f"t_{t}" for t in SHOT_TYPES],
    "tgt_x", "tgt_d",
]
N_FEATURES = len(FEATURE_NAMES)
NET_Y = 22.0
UP_DIST = 9.5
HEIGHT_FT = [1.3, 3.1, 5.0]
PACE_FTS = [18.0, 34.0, 50.0]


def features_for(state: dict, shot_type: str, target: dict) -> list[float]:
    """state: {hitTeam, hitter, players:[{x,y}]*4, ball:{x,y}, height, pace, shotNo,
    contactHeightFt?, incomingSpeed?}; target: {x, y} in engine coordinates."""
    T = state["hitTeam"]
    O = 1 - T

    def mx(x: float) -> float:
        return x - 10 if T == 0 else 10 - x

    def d(y: float) -> float:
        return abs(y - NET_Y)

    def up(p: dict) -> int:
        return 1 if d(p["y"]) <= UP_DIST else 0

    players = state["players"]
    partner = players[state["hitter"] ^ 1]
    opps = sorted([players[O * 2], players[O * 2 + 1]], key=lambda p: mx(p["x"]))
    mine = [players[T * 2], players[T * 2 + 1]]
    hh = state.get("contactHeightFt")
    sp = state.get("incomingSpeed")
    return [
        mx(state["ball"]["x"]), d(state["ball"]["y"]),
        hh if hh is not None else HEIGHT_FT[state["height"]],
        sp if sp is not None else PACE_FTS[state["pace"]],
        float(min(state["shotNo"], 12)),
        mx(partner["x"]), d(partner["y"]),
        mx(opps[0]["x"]), d(opps[0]["y"]), mx(opps[1]["x"]), d(opps[1]["y"]),
        float(up(opps[0]) + up(opps[1])), float(up(mine[0]) + up(mine[1])),
        *[1.0 if t == shot_type else 0.0 for t in SHOT_TYPES],
        mx(target["x"]), d(target["y"]),
    ]


def world_to_engine(x: float, z: float) -> dict:
    """Court feet with the net on z = 0 (team 0 on +z) → engine coordinates."""
    return {"x": x + 10.0, "y": z + 22.0}
