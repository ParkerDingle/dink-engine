import json
from pathlib import Path

import pytest

from dink_ml.features import FEATURE_VERSION, N_FEATURES, features_for

FIX = json.loads((Path(__file__).parent / "fixtures" / "feature_parity.json").read_text())


def test_version_matches_game():
    assert FIX["feature_version"] == FEATURE_VERSION


@pytest.mark.parametrize("case", FIX["cases"])
def test_features_match_typescript(case):
    got = features_for(case["state"], case["type"], case["target"])
    assert len(got) == N_FEATURES
    assert got == pytest.approx(case["features"], abs=1e-9)
