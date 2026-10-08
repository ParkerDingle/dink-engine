"""Turn tracks + events + rally outcomes into a shot table in the model's feature format.

Inputs
  tracks.csv   from dink_ml.track (players and ball per frame)
  rallies.csv  one row per rally: rally_id,start_frame,end_frame,winner  (winner = near | far)
Team 0 is the side nearest the camera (court z > 0), team 1 the far side.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .events import detect_events
from .features import FEATURE_NAMES, features_for, world_to_engine

PLAYER_HEIGHT_FT = 5.8


def classify_shot(hit_d: float, contact_h: float, land_d: float | None, speed: float) -> str:
    """Heuristic shot label until a learned classifier replaces it.
    hit_d: hitter's distance from the net; land_d: where it landed (None if volleyed); speed: ft/s."""
    if contact_h > 4.5 and speed > 40:
        return "putaway"
    if land_d is not None and land_d > 15 and speed < 30:
        return "lob"
    if speed < 30 and (land_d is None or land_d <= 8):
        return "dink" if hit_d <= 9.5 else "drop"
    return "speedup" if hit_d <= 9.5 else "drive"


def _players_at(players: pd.DataFrame, frame: int) -> pd.DataFrame:
    f = players["frame"].to_numpy()
    nearest = f[np.argmin(np.abs(f - frame))]
    return players[players["frame"] == nearest]


def _order_players(snap: pd.DataFrame) -> list[dict] | None:
    near = snap[snap["z"] > 0].sort_values("x")
    far = snap[snap["z"] < 0].sort_values("x")
    if len(near) < 2 or len(far) < 2:
        return None
    rows = [*near.head(2).to_dict("records"), *far.head(2).to_dict("records")]
    return rows


def build_shot_table(tracks: pd.DataFrame, rallies: pd.DataFrame, fps: float = 30.0) -> pd.DataFrame:
    players = tracks[tracks["kind"] == "player"]
    ball = tracks[tracks["kind"] == "ball"].sort_values("frame")
    out = []
    for r in rallies.itertuples():
        b = ball[(ball["frame"] >= r.start_frame) & (ball["frame"] <= r.end_frame)]
        if len(b) < 10:
            continue
        frames = b["frame"].to_numpy()
        near = np.zeros(len(b), bool)
        for i, fr in enumerate(frames):
            snap = _players_at(players, fr)
            if len(snap):
                dist = np.hypot(snap["u"].to_numpy() - b["u"].iloc[i], (snap["v"].to_numpy() + snap["box_top"].to_numpy()) / 2 - b["v"].iloc[i])
                tall = np.maximum(snap["v"].to_numpy() - snap["box_top"].to_numpy(), 1)
                near[i] = bool(np.any(dist < tall * 0.9))
        events = detect_events(frames, b["u"].to_numpy(), b["v"].to_numpy(), b["z"].to_numpy(), near)
        hits = [e for e in events if e.kind == "hit"]
        winner_team = 0 if str(r.winner).lower().startswith("n") else 1
        for k, h in enumerate(hits):
            shot_no = k + 1
            if shot_no == 1:
                continue  # serves aren't decisions the model scores
            snap = _players_at(players, h.frame)
            ordered = _order_players(snap)
            if ordered is None:
                continue
            ppx = np.array([[p["u"], p["v"]] for p in ordered])
            hitter = int(np.argmin(np.hypot(ppx[:, 0] - h.u, ppx[:, 1] - h.v)))
            hp = ordered[hitter]
            team = 0 if hitter < 2 else 1
            contact_h = float(np.clip((hp["v"] - h.v) / max(hp["v"] - hp["box_top"], 1) * PLAYER_HEIGHT_FT, 0.3, 8.0))
            prev = next((e for e in reversed(events) if e.frame < h.frame), None)
            nxt = next((e for e in events if e.frame > h.frame), None)
            dt_in = (h.frame - prev.frame) / fps if prev else 0.5
            prev_pos = b.loc[b["frame"] == prev.frame, ["x", "z"]].to_numpy()[0] if prev is not None and (b["frame"] == prev.frame).any() else np.array([hp["x"], -hp["z"]])
            speed = float(np.hypot(hp["x"] - prev_pos[0], hp["z"] - prev_pos[1]) / max(dt_in, 0.05))
            if nxt is not None and (b["frame"] == nxt.frame).any():
                tgt = b.loc[b["frame"] == nxt.frame, ["x", "z"]].to_numpy()[0]
            else:
                tgt = np.array([0.0, -np.sign(hp["z"]) * 10])
            land_d = abs(float(tgt[1])) if nxt is not None and nxt.kind == "bounce" else None
            shot = classify_shot(abs(hp["z"]), contact_h, land_d, speed)
            state = {
                "hitTeam": team, "hitter": hitter,
                "players": [world_to_engine(p["x"], p["z"]) for p in ordered],
                "ball": world_to_engine(hp["x"], hp["z"]),
                "height": 0 if contact_h < 2.3 else 1 if contact_h < 4.0 else 2,
                "pace": 0 if speed < 27 else 1 if speed < 42 else 2,
                "shotNo": shot_no, "contactHeightFt": contact_h, "incomingSpeed": speed,
            }
            feats = features_for(state, shot, world_to_engine(float(tgt[0]), float(tgt[1])))
            out.append([*feats, int(team == winner_team), r.rally_id, int(h.frame), shot])
    return pd.DataFrame(out, columns=[*FEATURE_NAMES, "won", "rally_id", "frame", "shot_type"])
