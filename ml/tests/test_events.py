import numpy as np

from dink_ml.events import detect_events


def synthetic_dink_rally():
    """Ball goes near (z=+8) -> far (z=-8) -> near, bouncing once on each side before each hit."""
    frames, u, v, z, near = [], [], [], [], []
    f = 0
    for leg in range(4):
        z0, z1 = (8, -8) if leg % 2 == 0 else (-8, 8)
        n = 30
        for i in range(n):
            s = i / (n - 1)
            zz = z0 + (z1 - z0) * s
            # screen height: an arc to the bounce at s=0.8, then a small rebound
            arc = 60 * 4 * (s / 0.8) * (1 - s / 0.8) if s <= 0.8 else 25 * 4 * ((s - 0.8) / 0.2) * (1 - (s - 0.8) / 0.2)
            frames.append(f); u.append(640.0); v.append(400 - arc + zz * 5); z.append(zz); near.append(i < 2 or i > n - 3)
            f += 1
    return np.array(frames), np.array(u), np.array(v), np.array(z), np.array(near)


def test_finds_bounces_and_hits():
    ev = detect_events(*synthetic_dink_rally())
    kinds = [e.kind for e in ev]
    assert kinds.count("bounce") >= 3
    assert kinds.count("hit") >= 2
