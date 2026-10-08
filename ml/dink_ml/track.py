"""Track players and the ball in broadcast footage.

Players: YOLO person detection + ByteTrack (via supervision), projected to court feet through the
court homography. Ball: a YOLO model fine-tuned on pickleball frames (e.g. a Roboflow Universe
pickleball dataset) passed as --ball-model; TrackNet-style heatmap models are a later upgrade.

Output CSV columns: frame, t, kind (player|ball), track_id, u, v, x, z, conf, box_top
"""
from __future__ import annotations

import csv
from pathlib import Path

import numpy as np

from .court import CourtCalibration, foot_point


def track_video(video: str, court_json: str, out_csv: str, player_model: str = "yolo11n.pt",
                ball_model: str | None = None, conf: float = 0.25, stride: int = 1, max_frames: int | None = None) -> int:
    try:
        import supervision as sv
        from ultralytics import YOLO
    except ImportError as e:  # pragma: no cover - optional dependency
        raise SystemExit("Install the tracking extras first: pip install -e '.[cv]'") from e
    import cv2

    court = CourtCalibration.load(court_json)
    players = YOLO(player_model)
    ball = YOLO(ball_model) if ball_model else None
    tracker = sv.ByteTrack()
    cap = cv2.VideoCapture(video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    rows = 0
    Path(out_csv).parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["frame", "t", "kind", "track_id", "u", "v", "x", "z", "conf", "box_top"])
        frame = -1
        while True:
            ok, img = cap.read()
            if not ok:
                break
            frame += 1
            if frame % stride:
                continue
            if max_frames and frame >= max_frames:
                break
            t = frame / fps
            det = sv.Detections.from_ultralytics(players(img, classes=[0], conf=conf, verbose=False)[0])
            det = tracker.update_with_detections(det)
            if len(det):
                feet = foot_point(det.xyxy)
                xz = court.to_court(feet)
                on_court = (np.abs(xz[:, 0]) < 16) & (np.abs(xz[:, 1]) < 30)
                for k in np.where(on_court)[0]:
                    w.writerow([frame, f"{t:.3f}", "player", int(det.tracker_id[k]), *np.round(feet[k], 1), *np.round(xz[k], 2), f"{det.confidence[k]:.2f}", f"{det.xyxy[k, 1]:.1f}"])
                    rows += 1
            if ball is not None:
                res = ball(img, conf=conf, verbose=False)[0]
                if len(res.boxes):
                    b = res.boxes[int(res.boxes.conf.argmax())]
                    x1, y1, x2, y2 = b.xyxy[0].tolist()
                    uv = np.array([[(x1 + x2) / 2, (y1 + y2) / 2]])
                    xz = court.to_court(uv)[0]  # ground projection; only exact at bounces
                    w.writerow([frame, f"{t:.3f}", "ball", -1, *np.round(uv[0], 1), *np.round(xz, 2), f"{float(b.conf):.2f}", ""])
                    rows += 1
    cap.release()
    return rows
