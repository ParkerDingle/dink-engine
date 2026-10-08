"""Find hits and bounces in a ball track.

Works on image coordinates (u right, v down). A bounce shows up as the ball's screen-vertical
motion switching from falling (v increasing) to rising while it is away from any player; a hit is a
reversal of the ball's direction along the court (toward / away from the camera) near a player.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Event:
    frame: int
    kind: str          # "hit" | "bounce"
    u: float
    v: float


def smooth(x: np.ndarray, k: int = 3) -> np.ndarray:
    if len(x) < k:
        return x.astype(float)
    pad = k // 2
    xp = np.pad(x.astype(float), pad, mode="edge")
    return np.array([np.median(xp[i:i + k]) for i in range(len(x))])


def detect_events(frames: np.ndarray, u: np.ndarray, v: np.ndarray, court_z: np.ndarray,
                  near_player: np.ndarray | None = None, min_gap: int = 4) -> list[Event]:
    """frames/u/v: ball track (sorted, gaps allowed). court_z: ground-projected court z per sample.
    near_player: bool per sample, True when the ball is within reach of a tracked player."""
    frames = np.asarray(frames)
    us, vs, zs = smooth(np.asarray(u)), smooth(np.asarray(v)), smooth(np.asarray(court_z), 5)
    near = np.zeros(len(frames), bool) if near_player is None else np.asarray(near_player, bool)
    out: list[Event] = []
    last = -10 ** 9
    for i in range(3, len(frames) - 3):
        if frames[i] - last < min_gap:
            continue
        before, after = zs[i] - zs[i - 3], zs[i + 3] - zs[i]
        if near[i] and before * after < 0 and abs(before) > 0.15 and abs(after) > 0.15:
            out.append(Event(int(frames[i]), "hit", float(us[i]), float(vs[i]))); last = frames[i]
            continue
        lowest = vs[i] >= vs[i - 1] and vs[i] >= vs[i + 1]       # lowest point on screen
        if not near[i] and lowest and vs[i] - vs[i - 3] > 2 and vs[i] - vs[i + 3] > 2:
            out.append(Event(int(frames[i]), "bounce", float(us[i]), float(vs[i]))); last = frames[i]
    return out
