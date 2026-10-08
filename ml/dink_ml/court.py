"""Court calibration: map broadcast-video pixels to court feet with a planar homography.

Court frame: x across (sidelines at ±10 ft), z along (net at 0, near baseline at +22), feet.
Calibrate once per camera angle by clicking (or detecting) at least four known court points.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

# Known court landmarks in court feet (x, z). "near" is the baseline closest to the camera.
LANDMARKS: dict[str, tuple[float, float]] = {
    "near_left": (-10, 22), "near_right": (10, 22), "far_left": (-10, -22), "far_right": (10, -22),
    "near_kitchen_left": (-10, 7), "near_kitchen_right": (10, 7), "far_kitchen_left": (-10, -7), "far_kitchen_right": (10, -7),
    "near_center": (0, 22), "far_center": (0, -22), "near_kitchen_center": (0, 7), "far_kitchen_center": (0, -7),
}


@dataclass
class CourtCalibration:
    H: np.ndarray                      # pixel -> court
    pixels: dict[str, tuple[float, float]] = field(default_factory=dict)

    @classmethod
    def from_points(cls, pixels: dict[str, tuple[float, float]]) -> "CourtCalibration":
        names = [n for n in pixels if n in LANDMARKS]
        if len(names) < 4:
            raise ValueError("need at least 4 known court landmarks")
        src = np.array([pixels[n] for n in names], dtype=np.float64)
        dst = np.array([LANDMARKS[n] for n in names], dtype=np.float64)
        H, _ = cv2.findHomography(src, dst, method=cv2.RANSAC if len(names) > 8 else 0)
        if H is None:
            raise ValueError("could not fit a homography to these points")
        return cls(H=H, pixels={n: tuple(pixels[n]) for n in names})

    @classmethod
    def load(cls, path: str | Path) -> "CourtCalibration":
        data = json.loads(Path(path).read_text())
        return cls.from_points({k: tuple(v) for k, v in data["pixels"].items()})

    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps({"pixels": self.pixels}, indent=2))

    def to_court(self, uv: np.ndarray) -> np.ndarray:
        """(N,2) pixels -> (N,2) court feet. Only valid for points on the ground (feet, bounces)."""
        pts = np.asarray(uv, dtype=np.float64).reshape(-1, 1, 2)
        return cv2.perspectiveTransform(pts, self.H).reshape(-1, 2)

    def to_pixel(self, xz: np.ndarray) -> np.ndarray:
        pts = np.asarray(xz, dtype=np.float64).reshape(-1, 1, 2)
        return cv2.perspectiveTransform(pts, np.linalg.inv(self.H)).reshape(-1, 2)

    def reprojection_error(self) -> float:
        names = list(self.pixels)
        proj = self.to_pixel(np.array([LANDMARKS[n] for n in names]))
        return float(np.mean(np.linalg.norm(proj - np.array([self.pixels[n] for n in names]), axis=1)))


def foot_point(box: np.ndarray) -> np.ndarray:
    """Bottom-center of xyxy boxes: where a player touches the ground."""
    b = np.asarray(box, dtype=np.float64).reshape(-1, 4)
    return np.stack([(b[:, 0] + b[:, 2]) / 2, b[:, 3]], axis=1)
