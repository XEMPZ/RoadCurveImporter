import json
import sys
from collections import Counter

import ezdxf


def main(path: str) -> None:
    try:
        document = ezdxf.readfile(path)
        modelspace = document.modelspace()
        entities = list(modelspace)
        type_counts = Counter(entity.dxftype() for entity in entities)
        spiral_polylines = []
        for entity in entities:
            if entity.dxftype() in {"LWPOLYLINE", "POLYLINE"} and entity.dxf.layer == "ROAD_SPIRAL_POLYLINE":
                if entity.dxftype() == "LWPOLYLINE":
                    points = [tuple(vertex[:2]) for vertex in entity]
                    closed = bool(entity.closed)
                else:
                    points = [(float(vertex.dxf.location.x), float(vertex.dxf.location.y)) for vertex in entity.vertices]
                    closed = bool(entity.is_closed)
                spiral_polylines.append({
                    "entity_type": entity.dxftype(),
                    "vertices": len(points),
                    "closed": closed,
                    "start": list(points[0]) if points else None,
                    "end": list(points[-1]) if points else None,
                })
        print(json.dumps({
            "valid": True,
            "dxfversion": document.dxfversion,
            "entity_counts": dict(type_counts),
            "spiral_polyline_count": len(spiral_polylines),
            "spiral_polylines": spiral_polylines,
            "layers": sorted(layer.dxf.name for layer in document.layers),
        }, ensure_ascii=False, indent=2))
    except Exception as error:
        print(json.dumps({
            "valid": False,
            "error_type": type(error).__name__,
            "error": str(error),
        }, ensure_ascii=False, indent=2))
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_dxf_ezdxf.py <file.dxf>")
    main(sys.argv[1])
