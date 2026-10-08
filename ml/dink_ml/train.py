"""Train the shot-value model and export it to ONNX for the game.

Input: one or more shot-table CSVs with the columns in features.FEATURE_NAMES plus `won`
(1 if the hitting team won the rally) and `rally_id` (used to keep rallies on one side of the split).
Output: <out_dir>/shot_value.onnx and <out_dir>/model_card.json, which the game loads at startup.

    python -m dink_ml.train data/selfplay.csv --out ../game/public/models
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.metrics import log_loss, roc_auc_score

from .features import FEATURE_NAMES, FEATURE_VERSION, N_FEATURES

PARAMS = dict(
    objective="binary", learning_rate=0.05, num_leaves=31, min_child_samples=80,
    feature_fraction=0.9, bagging_fraction=0.8, bagging_freq=1, lambda_l2=1.0, verbose=-1,
)


def load(paths: list[str]) -> pd.DataFrame:
    frames = []
    for i, p in enumerate(paths):
        df = pd.read_csv(p)
        missing = [c for c in [*FEATURE_NAMES, "won"] if c not in df.columns]
        if missing:
            raise ValueError(f"{p} is missing columns: {missing}")
        if "rally_id" not in df.columns:
            df["rally_id"] = np.arange(len(df))
        df["rally_id"] = df["rally_id"].astype(str) + f"@{i}"
        frames.append(df)
    return pd.concat(frames, ignore_index=True)


def split_by_rally(df: pd.DataFrame, valid_frac: float, seed: int):
    rallies = df["rally_id"].unique()
    rng = np.random.default_rng(seed)
    valid = set(rng.choice(rallies, size=max(1, int(len(rallies) * valid_frac)), replace=False))
    mask = df["rally_id"].isin(valid)
    return df[~mask], df[mask]


def calibration_table(y: np.ndarray, p: np.ndarray, bins: int = 10) -> list[dict]:
    edges = np.linspace(0, 1, bins + 1)
    out = []
    for a, b in zip(edges[:-1], edges[1:]):
        m = (p >= a) & (p < b)
        if m.sum() >= 50:
            out.append({"bin": f"{a:.1f}-{b:.1f}", "n": int(m.sum()), "predicted": round(float(p[m].mean()), 3), "actual": round(float(y[m].mean()), 3)})
    return out


def export_onnx(booster: lgb.Booster, path: Path) -> None:
    from onnxmltools import convert_lightgbm
    from onnxmltools.convert.common.data_types import FloatTensorType

    onx = convert_lightgbm(
        booster, initial_types=[("features", FloatTensorType([None, N_FEATURES]))],
        zipmap=False, target_opset=15,
    )
    for out in onx.graph.output:  # outputs are batched: make the batch dimension dynamic
        dims = out.type.tensor_type.shape.dim
        if len(dims):
            dims[0].Clear(); dims[0].dim_param = "N"
    path.write_bytes(onx.SerializeToString())


def check_onnx(path: Path, booster: lgb.Booster, X: np.ndarray) -> float:
    import onnxruntime as ort

    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    out = sess.run(["probabilities"], {"features": X.astype(np.float32)})[0][:, 1]
    return float(np.max(np.abs(out - booster.predict(X))))


def train(paths: list[str], out_dir: str, rounds: int = 600, seed: int = 0, source: str | None = None) -> dict:
    df = load(paths)
    tr, va = split_by_rally(df, 0.15, seed)
    Xtr, ytr = tr[FEATURE_NAMES].to_numpy(np.float32), tr["won"].to_numpy()
    Xva, yva = va[FEATURE_NAMES].to_numpy(np.float32), va["won"].to_numpy()
    booster = lgb.train(
        {**PARAMS, "seed": seed}, lgb.Dataset(Xtr, ytr, feature_name=list(FEATURE_NAMES)), num_boost_round=rounds,
        valid_sets=[lgb.Dataset(Xva, yva, feature_name=list(FEATURE_NAMES))],
        callbacks=[lgb.early_stopping(40, verbose=False)],
    )
    best = booster.best_iteration or rounds
    booster = lgb.Booster(model_str=booster.model_to_string(num_iteration=best))  # keep only the trees we use
    p = booster.predict(Xva)
    auc, ll = roc_auc_score(yva, p), log_loss(yva, p)
    base_ll = log_loss(yva, np.full_like(p, ytr.mean()))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    model_path = out / "shot_value.onnx"
    export_onnx(booster, model_path)
    drift = check_onnx(model_path, booster, Xva[:2000])
    gain = booster.feature_importance("gain")
    card = {
        "file": model_path.name, "feature_version": FEATURE_VERSION, "features": list(FEATURE_NAMES),
        "trained_on": ", ".join(Path(p).name for p in paths), "source": source or "shot table",
        "rows": int(len(df)), "rallies": int(df["rally_id"].nunique()), "trees": int(best),
        "auc": round(float(auc), 4), "log_loss": round(float(ll), 4), "baseline_log_loss": round(float(base_ll), 4),
        "onnx_max_abs_diff": drift, "calibration": calibration_table(yva, p),
        "top_features": [n for _, n in sorted(zip(gain, FEATURE_NAMES), reverse=True)[:8]],
        "created": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    (out / "model_card.json").write_text(json.dumps(card, indent=2))
    return card


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+", help="shot-table CSV files")
    ap.add_argument("--out", default="../game/public/models")
    ap.add_argument("--rounds", type=int, default=600)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--source", default=None, help="short description stored in the model card")
    a = ap.parse_args(argv)
    card = train(a.csv, a.out, a.rounds, a.seed, a.source)
    print(json.dumps({k: card[k] for k in ["rows", "rallies", "trees", "auc", "log_loss", "baseline_log_loss", "onnx_max_abs_diff", "top_features"]}, indent=2))


if __name__ == "__main__":
    main()
