"""dink-ml command line.

  dink-ml calibrate court.json --point near_left 212 655 --point near_right 1068 655 ...
  dink-ml track match.mp4 --court court.json --ball-model ball.pt --out data/tracks.csv
  dink-ml shots data/tracks.csv data/rallies.csv --out data/shots.csv
  dink-ml train data/shots.csv data/selfplay.csv --out ../game/public/models
"""
from __future__ import annotations

import argparse
import json
import sys


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="dink-ml", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("calibrate", help="save a court calibration from known landmark pixels")
    c.add_argument("out"); c.add_argument("--point", nargs=3, action="append", metavar=("NAME", "U", "V"), required=True)

    t = sub.add_parser("track", help="detect and track players (and the ball) in a video")
    t.add_argument("video"); t.add_argument("--court", required=True); t.add_argument("--out", default="data/tracks.csv")
    t.add_argument("--player-model", default="yolo11n.pt"); t.add_argument("--ball-model"); t.add_argument("--stride", type=int, default=1)
    t.add_argument("--max-frames", type=int)

    s = sub.add_parser("shots", help="build a shot table from tracks and rally outcomes")
    s.add_argument("tracks"); s.add_argument("rallies"); s.add_argument("--out", default="data/shots.csv"); s.add_argument("--fps", type=float, default=30.0)

    tr = sub.add_parser("train", help="train the shot-value model and export ONNX for the game")
    tr.add_argument("csv", nargs="+"); tr.add_argument("--out", default="../game/public/models"); tr.add_argument("--rounds", type=int, default=600)
    tr.add_argument("--source", default=None)

    a = ap.parse_args(argv)
    if a.cmd == "calibrate":
        from .court import CourtCalibration
        cal = CourtCalibration.from_points({n: (float(u), float(v)) for n, u, v in a.point})
        cal.save(a.out)
        print(f"saved {a.out} · mean reprojection error {cal.reprojection_error():.2f}px")
    elif a.cmd == "track":
        from .track import track_video
        n = track_video(a.video, a.court, a.out, a.player_model, a.ball_model, stride=a.stride, max_frames=a.max_frames)
        print(f"wrote {n} rows to {a.out}")
    elif a.cmd == "shots":
        import pandas as pd
        from .shots import build_shot_table
        df = build_shot_table(pd.read_csv(a.tracks), pd.read_csv(a.rallies), a.fps)
        df.to_csv(a.out, index=False)
        print(f"wrote {len(df)} shots to {a.out}")
    elif a.cmd == "train":
        from .train import train
        card = train(a.csv, a.out, a.rounds, source=a.source)
        json.dump({k: card[k] for k in ["rows", "auc", "log_loss", "baseline_log_loss", "top_features"]}, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
