import json

import numpy as np
import pandas as pd

from dink_ml.features import FEATURE_NAMES
from dink_ml.shots import classify_shot
from dink_ml.train import train


def test_train_exports_working_onnx(tmp_path):
    rng = np.random.default_rng(0)
    n = 6000
    X = rng.normal(size=(n, len(FEATURE_NAMES))).astype(np.float32)
    logit = 1.2 * X[:, 0] - 0.8 * X[:, 3] + 0.5 * X[:, 19]
    y = (rng.random(n) < 1 / (1 + np.exp(-logit))).astype(int)
    df = pd.DataFrame(X, columns=FEATURE_NAMES)
    df["won"] = y
    df["rally_id"] = np.arange(n) // 6
    csv = tmp_path / "shots.csv"
    df.to_csv(csv, index=False)
    card = train([str(csv)], str(tmp_path / "out"), rounds=80)
    assert card["auc"] > 0.7
    assert card["onnx_max_abs_diff"] < 1e-4
    saved = json.loads((tmp_path / "out" / "model_card.json").read_text())
    assert saved["file"] == "shot_value.onnx" and (tmp_path / "out" / "shot_value.onnx").exists()


def test_classify_shot():
    assert classify_shot(8, 1.5, 4, 18) == "dink"
    assert classify_shot(21, 1.5, 4, 25) == "drop"
    assert classify_shot(21, 2.5, 18, 50) == "drive"
    assert classify_shot(8, 5.2, 10, 55) == "putaway"
    assert classify_shot(8, 1.5, 19, 24) == "lob"
