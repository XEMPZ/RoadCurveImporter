#!/usr/bin/env python3
"""Euler-spiral fitter for RoadCurveImporter.

The integration grid is deliberately tighter than 0.5 mm while avoiding the
previous unnecessarily dense grid that delayed complex-route import.
Input JSON: {points:[[x,y],...], tolerance_m:0.0005}
"""
import json, math, sys
from pathlib import Path
import numpy as np
try:
    from scipy.optimize import least_squares
except Exception as exc:
    raise SystemExit(f"缺少 scipy，无法执行欧拉回旋线验收：{exc}")


def integrate(theta0, k0, k1, length, stations, steps_per_m=80):
    stations = np.asarray(stations, float)
    out = []
    x = y = s = 0.0
    for target in stations:
        while s < target - 1e-13:
            h = min(1.0 / steps_per_m, target - s)
            def angle(t):
                return theta0 + k0 * t + 0.5 * (k1 - k0) * t * t / length
            a1 = angle(s)
            a2 = angle(s + h / 2)
            a4 = angle(s + h)
            x += h * (math.cos(a1) + 4 * math.cos(a2) + math.cos(a4)) / 6
            y += h * (math.sin(a1) + 4 * math.sin(a2) + math.sin(a4)) / 6
            s += h
        out.append((x, y))
    return np.asarray(out)


def fit(points, tolerance):
    if points and isinstance(points[0], dict):
        points = [[p.get("x", p.get("X")), p.get("y", p.get("Y"))] for p in points]
    pts = np.asarray(points, float)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    chord = np.r_[0, np.cumsum(seg)]
    length0 = float(chord[-1])
    if length0 <= 0:
        raise ValueError("回旋线候选长度为零")
    u = chord / length0
    dirs = np.arctan2(np.diff(pts[:, 1]), np.diff(pts[:, 0]))
    turns = np.unwrap(dirs)
    curv = np.diff(turns) / ((seg[:-1] + seg[1:]) / 2)
    stations = chord[1:-1]
    slope, intercept = np.polyfit(stations, curv, 1)
    scale = length0
    origin = pts[0]

    def unpack(q):
        return q[0], q[1] / scale, q[2] / scale, max(q[3] * scale, 1e-6)

    def residual(q):
        theta, k0, k1, length = unpack(q)
        model = integrate(theta, k0, k1, length, u * length) + origin
        return (model - pts).ravel()

    theta0 = float(dirs[0] - intercept * seg[0] / 2 - slope * seg[0] * seg[0] / 6)
    q0 = np.array([theta0, intercept * scale, (intercept + slope * length0) * scale, 1.0], float)
    sol = least_squares(residual, q0, method="trf", x_scale="jac", ftol=1e-12, xtol=1e-12, gtol=1e-12, max_nfev=500)
    theta, k0, k1, length = unpack(sol.x)
    model = integrate(theta, k0, k1, length, u * length, steps_per_m=160) + origin
    delta = np.linalg.norm(model - pts, axis=1)
    nonzero = curv[np.abs(curv) > 1e-8]
    one_direction = bool(nonzero.size and (np.all(nonzero > 0) or np.all(nonzero < 0)))
    max_err = float(delta.max())
    rms = float(math.sqrt(np.mean(delta * delta)))
    return {
        "success": bool(sol.success),
        "strict_pass": bool(sol.success and one_direction and max_err <= tolerance),
        "max_vertex_error_m": max_err,
        "rms_vertex_error_m": rms,
        "length_m": float(length),
        "start_heading_rad": float(theta),
        "end_heading_rad": float(theta + 0.5 * (k0 + k1) * length),
        "start_radius_m": 0.0 if abs(k0) < 1e-10 else float(-1.0 / k0),
        "end_radius_m": 0.0 if abs(k1) < 1e-10 else float(-1.0 / k1),
        "iterations": int(sol.nfev),
        "message": str(sol.message),
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit("用法: spiral_fitter.py input.json output.json")
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    result = fit(payload["points"], float(payload.get("tolerance_m", 0.0005)))
    Path(sys.argv[2]).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
