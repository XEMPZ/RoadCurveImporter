#!/usr/bin/env python3
"""Line-oriented persistent Euler-spiral fitting worker for RoadCurveImporter."""
import importlib.util
import json
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit('用法: spiral_fitter_server.py <spiral_fitter.py>')
module_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location('roadcurve_spiral_fitter', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fit = module.fit

for line in sys.stdin:
    try:
        request = json.loads(line)
        result = fit(request["points"], float(request.get("tolerance_m", 0.0005)))
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False), flush=True)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)
