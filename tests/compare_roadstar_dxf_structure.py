from __future__ import annotations

import json
import sys
from pathlib import Path


def pairs(path: Path):
    raw = path.read_text(encoding="cp1252").splitlines()
    if len(raw) % 2:
        raise ValueError(f"DXF 行数必须为偶数：{path}")
    return [(raw[i].strip(), raw[i + 1].strip()) for i in range(0, len(raw), 2)]


def sections(items):
    return [items[i + 1][1] for i in range(len(items) - 1) if items[i] == ("0", "SECTION") and items[i + 1][0] == "2"]


def entities(items, entity_name):
    result = []
    index = 0
    while index < len(items):
        if items[index] == ("0", entity_name):
            end = index + 1
            while end < len(items) and items[end][0] != "0":
                end += 1
            result.append(items[index + 1:end])
            index = end
        else:
            index += 1
    return result


def first_lwpolyline(items, layer=None):
    for body in entities(items, "LWPOLYLINE"):
        values = {}
        for code, value in body:
            values.setdefault(code, []).append(value)
        if layer is None or (values.get("8") or [""])[0] == layer:
            return values
    raise ValueError(f"未找到图层 {layer or '<任意>'} 的 LWPOLYLINE")


def summarize(values):
    xs = values.get("10", [])
    ys = values.get("20", [])
    zs = values.get("30", [])
    return {
        "codes": sorted(values),
        "layer": (values.get("8") or [""])[0],
        "subclasses": values.get("100", []),
        "declared_vertices": int((values.get("90") or ["0"])[0]),
        "x_vertices": len(xs),
        "y_vertices": len(ys),
        "z_vertices": len(zs),
        "open": (values.get("70") or [""])[0] == "0",
        "visible_attributes": {code: (values.get(code) or [""])[0] for code in ("62", "420", "370", "48", "6")},
    }


def main(reference: str, candidate: str, output: str):
    ref_items = pairs(Path(reference))
    cand_items = pairs(Path(candidate))
    ref = summarize(first_lwpolyline(ref_items))
    cand = summarize(first_lwpolyline(cand_items, "ROAD_SPIRAL_POLYLINE"))
    required_sections = {"HEADER", "TABLES", "BLOCKS", "ENTITIES", "OBJECTS"}
    required_codes = {"5", "8", "100", "90", "70", "10", "20", "30"}
    checks = {
        "reference_ac1015": any(code == "1" and value == "AC1015" for code, value in ref_items),
        "candidate_ac1015": any(code == "1" and value == "AC1015" for code, value in cand_items),
        "candidate_required_sections": required_sections.issubset(set(sections(cand_items))),
        "candidate_required_lwpolyline_codes": required_codes.issubset(set(cand["codes"])),
        "candidate_subclasses": {"AcDbEntity", "AcDbPolyline"}.issubset(set(cand["subclasses"])),
        "candidate_open": cand["open"],
        "candidate_vertex_counts_match": cand["declared_vertices"] == cand["x_vertices"] == cand["y_vertices"] == cand["z_vertices"],
        "candidate_visible_attributes": all(cand["visible_attributes"][code] != "" for code in ("62", "420", "370", "48", "6")),
    }
    payload = {"reference": summarize(first_lwpolyline(ref_items)), "candidate": cand, "reference_sections": sections(ref_items), "candidate_sections": sections(cand_items), "checks": checks, "passed": all(checks.values())}
    Path(output).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    if not payload["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: compare_roadstar_dxf_structure.py <reference.dxf> <candidate.dxf> <output.json>")
    main(*sys.argv[1:])
