import numpy as np
import pandas as pd

from dink_ml.export_luau import flatten, predict_flat, to_luau
from dink_ml.features import FEATURE_NAMES
from dink_ml.train import train


def test_luau_export_matches_lightgbm(tmp_path):
    rng = np.random.default_rng(1)
    n = 4000
    X = rng.normal(size=(n, len(FEATURE_NAMES)))
    y = (rng.random(n) < 1 / (1 + np.exp(-(X[:, 2] - X[:, 5])))).astype(int)
    df = pd.DataFrame(X, columns=FEATURE_NAMES); df["won"] = y; df["rally_id"] = np.arange(n) // 5
    csv = tmp_path / "s.csv"; df.to_csv(csv, index=False)
    card = train([str(csv)], str(tmp_path / "out"), rounds=40, luau_out=str(tmp_path / "ShotModel.luau"), lgb_out=str(tmp_path / "m.txt"))
    assert card["luau_max_abs_diff"] < 1e-6
    src = (tmp_path / "ShotModel.luau").read_text()
    assert "function M.predict" in src and 'M.featureVersion = "dink-features-v1"' in src


def test_single_leaf_trees_are_handled():
    import lightgbm as lgb
    X = np.zeros((200, len(FEATURE_NAMES))); y = np.r_[np.zeros(100), np.ones(100)]
    b = lgb.train({"objective": "binary", "verbose": -1, "min_data_in_leaf": 500}, lgb.Dataset(X, y), 3)
    trees = flatten(b)
    assert all(t["root"] == 0 for t in trees)
    assert np.allclose(predict_flat(trees, X[:5]), b.predict(X[:5]))
    assert "TREES" in to_luau(trees)


def test_parity_fixture_is_converted_to_luau(tmp_path):
    from pathlib import Path
    from dink_ml.export_luau import parity_fixture_luau
    src = Path(__file__).parent / "fixtures" / "feature_parity.json"
    out = parity_fixture_luau(src)
    assert out.count("features = {") == 40
    # player slots become 1-based for Luau
    assert "hitter = 1," in out and "hitter = 0," not in out
    committed = Path(__file__).parents[2] / "roblox" / "tests" / "fixtures" / "FeatureFixture.luau"
    assert committed.read_text() == out, "re-run: python -m dink_ml.export_luau --parity tests/fixtures/feature_parity.json ../roblox/tests/fixtures/FeatureFixture.luau"
