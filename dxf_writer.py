"""RoadCurveImporter standard DXF writer.

Reads one JSON object from stdin and writes an R2000 DXF using ezdxf.  The input
coordinates are always native CAD Cartesian X/Y coordinates; display options are
already excluded by the PowerShell caller.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import ezdxf


LAYERS = {
    "ROAD_CURVE": 7,
    "ROAD_GAP_FILL": 30,
    "ROAD_SPIRAL_POLYLINE": 5,
    "ROAD_DISCRETE_POLYLINE": 6,
}


def point(value: dict) -> tuple[float, float]:
    return float(value["X"]), float(value["Y"])


def apply_dxflib_polyline_compatibility(target: Path) -> None:
    """Match the dxflib 3.17 LWPOLYLINE vertex convention.

    dxflib emits code 30 = 0.0 after every x/y vertex in its open lightweight
    polylines.  Although elevation is normally optional for planar LWPOLYLINE,
    retaining it makes the exported spiral structurally align with the known
    ZWCAD-compatible reference output.
    """
    lines = target.read_text(encoding="cp1252").splitlines()
    output: list[str] = []
    in_lwpolyline = False
    layer = ""
    index = 0
    while index + 1 < len(lines):
        code = lines[index]
        value = lines[index + 1]
        stripped_code = code.strip()
        stripped_value = value.strip()
        if stripped_code == "0":
            in_lwpolyline = stripped_value == "LWPOLYLINE"
            layer = ""
        if in_lwpolyline and stripped_code == "8":
            layer = stripped_value
        output.extend((code, value))
        if in_lwpolyline and layer == "ROAD_SPIRAL_POLYLINE":
            if stripped_code == "62":
                # dxflib reference writes explicit true colour after ACI colour.
                output.extend(("420", "16711935"))
            elif stripped_code == "370":
                # dxflib reference writes linetype scale after lineweight.
                output.extend((" 48", "1.0"))
            elif stripped_code == "20":
                output.extend((" 30", "0.0"))
        index += 2
    if index < len(lines):
        output.append(lines[index])
    target.write_text("\n".join(output) + "\n", encoding="cp1252", newline="\n")


def write(payload: dict) -> dict:
    target = Path(payload["target_path"])
    # dxflib 3.17 export samples are AC1015 with a complete
    # TABLES/BLOCKS/OBJECTS structure and open LWPOLYLINE entities.
    # ezdxf writes the same R2000 structural baseline rather than a hand-crafted
    # partial ENTITIES section.
    doc = ezdxf.new("R2000", setup=True)
    doc.header["$INSUNITS"] = 6  # metres
    for name, color in LAYERS.items():
        if name not in doc.layers:
            doc.layers.add(name=name, dxfattribs={"color": color})

    msp = doc.modelspace()
    counts = {"LINE": 0, "ARC": 0, "LWPOLYLINE": 0, "spiral": 0, "discrete": 0}
    for item in payload["elements"]:
        kind = item["Kind"]
        if kind == "直线" or bool(item.get("IsGapFill", False)):
            layer = "ROAD_GAP_FILL" if bool(item.get("IsGapFill", False)) else "ROAD_CURVE"
            msp.add_line(point(item["Start"]), point(item["End"]), dxfattribs={"layer": layer})
            counts["LINE"] += 1
        elif kind == "圆曲线":
            center = point(item["Center"])
            start = point(item["Start"])
            sweep = float(item["Sweep"])
            start_angle = math.degrees(math.atan2(start[1] - center[1], start[0] - center[0]))
            end_angle = start_angle + math.degrees(sweep)
            if sweep < 0:
                start_angle, end_angle = end_angle, start_angle
            msp.add_arc(center, abs(float(item["Radius"])), start_angle, end_angle, dxfattribs={"layer": "ROAD_CURVE"})
            counts["ARC"] += 1
        else:
            vertices = [point(vertex) for vertex in item.get("Vertices", [])]
            if len(vertices) < 2:
                raise ValueError(f"{kind} has fewer than two DXF vertices: {item.get('Handle', '')}")
            spiral = kind == "缓和曲线"
            layer = "ROAD_SPIRAL_POLYLINE" if spiral else "ROAD_DISCRETE_POLYLINE"
            msp.add_lwpolyline(
                vertices,
                format="xy",
                close=False,
                dxfattribs={
                    "layer": layer,
                    # Match the dxflib sample: explicit visible colour,
                    # true colour, Continuous linetype, lineweight and scale.
                    "color": 6,
                    "true_color": 16711935,
                    "linetype": "Continuous",
                    "lineweight": 0,
                    "ltscale": 1.0,
                },
            )
            counts["LWPOLYLINE"] += 1
            counts["spiral" if spiral else "discrete"] += 1

    target.parent.mkdir(parents=True, exist_ok=True)
    doc.saveas(target)
    apply_dxflib_polyline_compatibility(target)
    return {"target_path": str(target), "dxfversion": doc.dxfversion, "counts": counts}


def main() -> None:
    payload = json.load(sys.stdin)
    result = write(payload)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
