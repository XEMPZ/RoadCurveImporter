namespace RoadCurve.Core;

/// <summary>
/// 端点连接与拓扑排序：≤300 元素走暴力链式，更多走空间网格桶。
/// 端口：Order-Elements / Order-LargeElementsSpatial / Optimize-RouteDirection / Add-EndpointFill。
/// </summary>
public class TopologySorter
{
    private readonly List<string> _diagnostics;
    private readonly double _connectionToleranceM;

    public TopologySorter(List<string> diagnostics, double connectionToleranceM)
    {
        _diagnostics = diagnostics;
        _connectionToleranceM = connectionToleranceM;
    }

    private void AddEndpointFill(List<RoadElement> ordered, RoadElement from, RoadElement to, double distance)
    {
        if (distance < Limits.MinGapFillM) return;
        var fill = ElementFactory.NewGapFill(from.End, to.Start, from, to, distance, _connectionToleranceM);
        ordered.Add(fill);
        _diagnostics.Add(fill.Note);
    }

    private static int GetEndpointDegree(List<RoadElement> items, Point2 point, double tol)
    {
        int count = 0;
        foreach (var e in items)
        {
            if (Geometry.Distance(e.Start, point) <= tol) count++;
            if (Geometry.Distance(e.End, point) <= tol) count++;
        }
        return count;
    }

    public List<RoadElement> OptimizeRouteDirection(List<RoadElement> items)
    {
        if (items.Count < 2) return items;
        int keep = 0, flip = 0;
        foreach (var e in items)
        {
            if (e.IsGapFill) continue;
            if (e.Reversed) flip++; else keep++;
        }
        if (flip > keep)
        {
            var result = new List<RoadElement>(items.Count);
            for (int i = items.Count - 1; i >= 0; i--) result.Add(ElementFactory.Reverse(items[i]));
            _diagnostics.Add($"智能方向判定：已采用与 CAD 原始实体方向一致性更高的线路正向（保留 {flip} 段，反向匹配 {keep} 段）。");
            return result;
        }
        _diagnostics.Add($"智能方向判定：已采用与 CAD 原始实体方向一致性更高的线路正向（保留 {keep} 段，反向匹配 {flip} 段）。");
        return items;
    }

    public List<RoadElement> Order(List<RoadElement> items)
    {
        double tol = _connectionToleranceM;
        if (items.Count > Limits.SpatialSortThreshold)
        {
            _diagnostics.Add($"大量离散线元：{items.Count} 个道路段使用空间索引端点拓扑排序；不再依赖 CAD 枚举或框选顺序。");
            return OrderLargeSpatial(items, tol);
        }
        var remaining = new List<RoadElement>(items);
        var ordered = new List<RoadElement>(items.Count);
        while (remaining.Count > 0)
        {
            var seed = remaining[0];
            string startSide = "Start";
            if (GetEndpointDegree(remaining, seed.End, tol) == 1 && GetEndpointDegree(remaining, seed.Start, tol) != 1)
                startSide = "End";
            if (startSide == "End") seed = ElementFactory.Reverse(seed);
            ordered.Add(seed);
            remaining.RemoveAt(0);
            Point2 current = seed.End;
            var previous = seed;
            bool connected = true;
            while (connected && remaining.Count > 0)
            {
                connected = false;
                for (int i = 0; i < remaining.Count; i++)
                {
                    var candidate = remaining[i];
                    double startDistance = Geometry.Distance(candidate.Start, current);
                    double endDistance = Geometry.Distance(candidate.End, current);
                    if (startDistance <= tol)
                    {
                        AddEndpointFill(ordered, previous, candidate, startDistance);
                        ordered.Add(candidate);
                        current = candidate.End; previous = candidate;
                        remaining.RemoveAt(i); connected = true; break;
                    }
                    if (endDistance <= tol)
                    {
                        var reversed = ElementFactory.Reverse(candidate);
                        AddEndpointFill(ordered, previous, reversed, endDistance);
                        ordered.Add(reversed);
                        current = reversed.End; previous = reversed;
                        remaining.RemoveAt(i); connected = true; break;
                    }
                }
            }
            if (remaining.Count > 0)
                _diagnostics.Add("检测到不连续或分叉实体：已从下一连通分量重新开始排序。");
        }
        return OptimizeRouteDirection(ordered);
    }

    private readonly record struct SpatialRecord(int Index, string Side, Point2 Point);

    private List<SpatialRecord> GetSpatialNeighbors(
        Dictionary<(long, long), List<SpatialRecord>> buckets, Point2 point,
        double cellSize, double tol, HashSet<int> visited, int excludeIndex)
    {
        var result = new List<SpatialRecord>();
        long gx = (long)Math.Floor(point.X / cellSize);
        long gy = (long)Math.Floor(point.Y / cellSize);
        for (long dx = -1; dx <= 1; dx++)
        for (long dy = -1; dy <= 1; dy++)
        {
            if (!buckets.TryGetValue((gx + dx, gy + dy), out var bucket)) continue;
            foreach (var record in bucket)
            {
                if (record.Index == excludeIndex || visited.Contains(record.Index)) continue;
                if (Geometry.Distance(record.Point, point) <= tol) result.Add(record);
            }
        }
        return result;
    }

    private (int Index, string Side, int Degree)? GetSpatialSeed(
        List<RoadElement> items, Dictionary<(long, long), List<SpatialRecord>> buckets,
        double cellSize, double tol, HashSet<int> visited)
    {
        (int Index, string Side, int Degree)? best = null;
        int bestDegree = int.MaxValue;
        for (int index = 0; index < items.Count; index++)
        {
            if (visited.Contains(index)) continue;
            var item = items[index];
            int startDegree = GetSpatialNeighbors(buckets, item.Start, cellSize, tol, visited, index).Count;
            int endDegree = GetSpatialNeighbors(buckets, item.End, cellSize, tol, visited, index).Count;
            string side = endDegree < startDegree ? "End" : "Start";
            int degree = Math.Min(startDegree, endDegree);
            if (best == null || degree < bestDegree)
            {
                best = (index, side, degree);
                bestDegree = degree;
                if (degree == 0) break;
            }
        }
        return best;
    }

    private List<RoadElement> OrderLargeSpatial(List<RoadElement> items, double tol)
    {
        if (items.Count == 0) return new List<RoadElement>();
        double cellSize = Math.Max(tol, 1e-9);
        var buckets = new Dictionary<(long, long), List<SpatialRecord>>();
        for (int index = 0; index < items.Count; index++)
        {
            var item = items[index];
            foreach (var (side, point) in new[] { ("Start", item.Start), ("End", item.End) })
            {
                var key = ((long)Math.Floor(point.X / cellSize), (long)Math.Floor(point.Y / cellSize));
                if (!buckets.TryGetValue(key, out var bucket)) buckets[key] = bucket = new List<SpatialRecord>();
                bucket.Add(new SpatialRecord(index, side, point));
            }
        }
        var visited = new HashSet<int>();
        var ordered = new List<RoadElement>(items.Count);
        int components = 0, branches = 0;
        while (visited.Count < items.Count)
        {
            var seed = GetSpatialSeed(items, buckets, cellSize, tol, visited);
            if (seed == null) break;
            var element = items[seed.Value.Index];
            if (seed.Value.Side == "End") element = ElementFactory.Reverse(element);
            visited.Add(seed.Value.Index);
            ordered.Add(element);
            Point2 current = element.End;
            var previous = element;
            components++;
            while (true)
            {
                var neighbors = GetSpatialNeighbors(buckets, current, cellSize, tol, visited, -1);
                if (neighbors.Count == 0) break;
                if (neighbors.Count > 1) branches++;
                var nextRecord = neighbors
                    .OrderBy(r => Geometry.Distance(r.Point, current))
                    .ThenBy(r => r.Index)
                    .ThenBy(r => r.Side, StringComparer.Ordinal)
                    .First();
                var next = items[nextRecord.Index];
                if (nextRecord.Side == "End") next = ElementFactory.Reverse(next);
                double distance = Geometry.Distance(next.Start, current);
                AddEndpointFill(ordered, previous, next, distance);
                ordered.Add(next);
                visited.Add(nextRecord.Index);
                current = next.End;
                previous = next;
            }
        }
        if (components > 1)
            _diagnostics.Add($"空间拓扑排序：发现 {components} 个不连通分量，已分别保持线内连续顺序。");
        if (branches > 0)
            _diagnostics.Add($"空间拓扑排序：发现 {branches} 次分叉候选，已按最近端点和稳定输入序号选择主线。");
        return OptimizeRouteDirection(ordered);
    }
}
