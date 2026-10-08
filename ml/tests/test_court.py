import numpy as np

from dink_ml.court import LANDMARKS, CourtCalibration, foot_point

# a plausible behind-the-baseline broadcast camera: court feet -> pixels
TRUE = np.array([[30.0, 4.0, 640.0], [0.0, -9.0, 420.0], [0.0, 0.009, 1.0]])


def project(xz):
    p = np.c_[xz, np.ones(len(xz))] @ TRUE.T
    return p[:, :2] / p[:, 2:]


def test_round_trip():
    names = ["near_left", "near_right", "far_left", "far_right", "near_kitchen_left", "far_kitchen_right"]
    px = project(np.array([LANDMARKS[n] for n in names]))
    cal = CourtCalibration.from_points(dict(zip(names, map(tuple, px))))
    assert cal.reprojection_error() < 1e-3
    pts = np.array([[0.0, 0.0], [5.0, 12.0], [-8.0, -19.0]])
    assert np.allclose(cal.to_court(project(pts)), pts, atol=1e-4)


def test_foot_point():
    assert np.allclose(foot_point([[10, 20, 30, 80]]), [[20, 80]])
