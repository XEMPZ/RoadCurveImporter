namespace RoadCurve.Core;

/// <summary>
/// 欧拉回旋线拟合，等价 spiral_fitter.py。
/// 模型：theta(s) = theta0 + k0*s + 0.5*(k1-k0)*s^2/L，Simpson 积分推进坐标。
/// 优化器为 Levenberg-Marquardt（数值雅可比），验收口径与原 scipy TRF 一致：
/// success + 曲率单号 + max_vertex_err ≤ tolerance → strict_pass。
/// </summary>
public static class SpiralFitter
{
    /// <summary>等价 Python integrate()：以 Simpson 步进生成 stations 处的坐标（原点为 (0,0)）。</summary>
    public static Point2[] Integrate(double theta0, double k0, double k1, double length, double[] stations, int stepsPerM = 80)
    {
        var output = new Point2[stations.Length];
        double x = 0, y = 0, s = 0;

        double Angle(double t) => theta0 + k0 * t + 0.5 * (k1 - k0) * t * t / length;

        for (int idx = 0; idx < stations.Length; idx++)
        {
            double target = stations[idx];
            while (s < target - 1e-13)
            {
                double h = Math.Min(1.0 / stepsPerM, target - s);
                double a1 = Angle(s);
                double a2 = Angle(s + h / 2);
                double a4 = Angle(s + h);
                x += h * (Math.Cos(a1) + 4 * Math.Cos(a2) + Math.Cos(a4)) / 6;
                y += h * (Math.Sin(a1) + 4 * Math.Sin(a2) + Math.Sin(a4)) / 6;
                s += h;
            }
            output[idx] = new Point2(x, y);
        }
        return output;
    }

    public sealed class FitResult
    {
        public bool Success;
        public bool StrictPass;
        public double MaxVertexErrorM;
        public double RmsVertexErrorM;
        public double LengthM;
        public double StartHeadingRad;
        public double EndHeadingRad;
        public double StartRadiusM;
        public double EndRadiusM;
        public int Iterations;
        public string Message = "";
    }

    /// <summary>等价 Python fit()。points 为原始折线顶点（CAD 笛卡尔坐标）。</summary>
    public static FitResult Fit(IReadOnlyList<Point2> points, double tolerance)
    {
        int n = points.Count;
        var pts = new double[n, 2];
        for (int i = 0; i < n; i++) { pts[i, 0] = points[i].X; pts[i, 1] = points[i].Y; }

        var seg = new double[n - 1];
        for (int i = 0; i < n - 1; i++)
        {
            double dx = pts[i + 1, 0] - pts[i, 0], dy = pts[i + 1, 1] - pts[i, 1];
            seg[i] = Math.Sqrt(dx * dx + dy * dy);
        }
        var chord = new double[n];
        for (int i = 1; i < n; i++) chord[i] = chord[i - 1] + seg[i - 1];
        double length0 = chord[n - 1];
        if (length0 <= 0) throw new ArgumentException("回旋线候选长度为零");
        var u = new double[n];
        for (int i = 0; i < n; i++) u[i] = chord[i] / length0;

        var dirs = new double[n - 1];
        for (int i = 0; i < n - 1; i++) dirs[i] = Math.Atan2(pts[i + 1, 1] - pts[i, 1], pts[i + 1, 0] - pts[i, 0]);
        var turns = Unwrap(dirs);
        var curv = new double[n - 2];
        for (int i = 0; i < n - 2; i++) curv[i] = (turns[i + 1] - turns[i]) / ((seg[i] + seg[i + 1]) / 2.0);
        var stations = new double[n - 2];
        for (int i = 0; i < n - 2; i++) stations[i] = chord[i + 1];
        PolyFit1(stations, curv, out double slope, out double intercept);

        double scale = length0;
        double originX = pts[0, 0], originY = pts[0, 1];

        (double Theta, double K0, double K1, double Length) Unpack(double[] q)
            => (q[0], q[1] / scale, q[2] / scale, Math.Max(q[3] * scale, 1e-6));

        double[] Residual(double[] q)
        {
            var (theta, k0, k1, length) = Unpack(q);
            var st = new double[n];
            for (int i = 0; i < n; i++) st[i] = u[i] * length;
            var model = Integrate(theta, k0, k1, length, st);
            var r = new double[2 * n];
            for (int i = 0; i < n; i++)
            {
                r[2 * i] = model[i].X + originX - pts[i, 0];
                r[2 * i + 1] = model[i].Y + originY - pts[i, 1];
            }
            return r;
        }

        double theta0 = dirs[0] - intercept * seg[0] / 2.0 - slope * seg[0] * seg[0] / 6.0;
        var q0 = new[] { theta0, intercept * scale, (intercept + slope * length0) * scale, 1.0 };

        var lm = LevenbergMarquardt(Residual, q0, maxNfev: 500);
        var (thetaF, k0F, k1F, lengthF) = Unpack(lm.X);
        var stEval = new double[n];
        for (int i = 0; i < n; i++) stEval[i] = u[i] * lengthF;
        var modelF = Integrate(thetaF, k0F, k1F, lengthF, stEval, stepsPerM: 160);
        double maxErr = 0, sumSq = 0;
        for (int i = 0; i < n; i++)
        {
            double dx = modelF[i].X + originX - pts[i, 0], dy = modelF[i].Y + originY - pts[i, 1];
            double d = Math.Sqrt(dx * dx + dy * dy);
            if (d > maxErr) maxErr = d;
            sumSq += d * d;
        }
        var nonzero = curv.Where(c => Math.Abs(c) > 1e-8).ToArray();
        bool oneDirection = nonzero.Length > 0 && (nonzero.All(c => c > 0) || nonzero.All(c => c < 0));

        return new FitResult
        {
            Success = lm.Success,
            StrictPass = lm.Success && oneDirection && maxErr <= tolerance,
            MaxVertexErrorM = maxErr,
            RmsVertexErrorM = Math.Sqrt(sumSq / n),
            LengthM = lengthF,
            StartHeadingRad = thetaF,
            EndHeadingRad = thetaF + 0.5 * (k0F + k1F) * lengthF,
            StartRadiusM = Math.Abs(k0F) < 1e-10 ? 0.0 : -1.0 / k0F,
            EndRadiusM = Math.Abs(k1F) < 1e-10 ? 0.0 : -1.0 / k1F,
            Iterations = lm.Nfev,
            Message = lm.Message
        };
    }

    /// <summary>np.unwrap 等价：把相邻角度差折叠到 (-π, π]。</summary>
    private static double[] Unwrap(double[] angles)
    {
        var output = (double[])angles.Clone();
        for (int i = 1; i < output.Length; i++)
        {
            double d = output[i] - output[i - 1];
            if (d > Math.PI) output[i] -= Geometry.Tau * Math.Ceiling((d - Math.PI) / Geometry.Tau);
            else if (d <= -Math.PI) output[i] += Geometry.Tau * Math.Ceiling((-Math.PI - d) / Geometry.Tau);
        }
        return output;
    }

    /// <summary>一元线性回归，返回 slope/intercept（np.polyfit deg=1）。</summary>
    private static void PolyFit1(double[] x, double[] y, out double slope, out double intercept)
    {
        int n = x.Length;
        double sumX = 0, sumY = 0, sumXX = 0, sumXY = 0;
        for (int i = 0; i < n; i++) { sumX += x[i]; sumY += y[i]; sumXX += x[i] * x[i]; sumXY += x[i] * y[i]; }
        double den = n * sumXX - sumX * sumX;
        slope = (n * sumXY - sumX * sumY) / den;
        intercept = (sumY - slope * sumX) / n;
    }

    private sealed class LmResult
    {
        public double[] X = Array.Empty<double>();
        public bool Success;
        public int Nfev;
        public string Message = "";
    }

    /// <summary>
    /// Levenberg-Marquardt，收敛口径对齐 scipy least_squares(trf, x_scale='jac', ftol=xtol=gtol=1e-12)。
    /// </summary>
    private static LmResult LevenbergMarquardt(Func<double[], double[]> residual, double[] q0, int maxNfev)
    {
        const double ftol = 1e-12, xtol = 1e-12, gtol = 1e-12;
        int m = q0.Length;
        var q = (double[])q0.Clone();
        var r = residual(q);
        int nfev = 1;
        double cost = Dot(r, r);
        string message = "已达到最大函数求值次数。";
        bool success = false;
        double lambda = 1e-3;

        while (nfev < maxNfev)
        {
            int rn = r.Length;
            var jac = new double[rn, m];
            for (int j = 0; j < m; j++)
            {
                double h = Math.Sqrt(2.220446049250313e-16) * Math.Max(Math.Abs(q[j]), 1.0);
                var qStep = (double[])q.Clone();
                qStep[j] += h;
                var rStep = residual(qStep);
                nfev++;
                for (int i = 0; i < rn; i++) jac[i, j] = (rStep[i] - r[i]) / h;
            }

            // A = JᵀJ, g = Jᵀr
            var a = new double[m, m];
            var g = new double[m];
            for (int j = 0; j < m; j++)
            {
                for (int k = j; k < m; k++)
                {
                    double sum = 0;
                    for (int i = 0; i < rn; i++) sum += jac[i, j] * jac[i, k];
                    a[j, k] = sum; a[k, j] = sum;
                }
                double gs = 0;
                for (int i = 0; i < rn; i++) gs += jac[i, j] * r[i];
                g[j] = gs;
            }

            double gInf = 0;
            for (int j = 0; j < m; j++) gInf = Math.Max(gInf, Math.Abs(g[j]));
            if (gInf < gtol) { success = true; message = "梯度收敛（gtol）。"; break; }

            bool stepAccepted = false;
            for (int attempt = 0; attempt < 30 && nfev < maxNfev; attempt++)
            {
                var aLm = (double[,])a.Clone();
                for (int j = 0; j < m; j++)
                {
                    double diag = aLm[j, j];
                    aLm[j, j] = diag + lambda * Math.Max(diag, 1e-18);
                }
                if (!SolveSymmetric(aLm, g, out var delta)) { lambda *= 10; continue; }
                for (int j = 0; j < m; j++) delta[j] = -delta[j];

                double deltaNorm = 0, qNorm = 0;
                for (int j = 0; j < m; j++) { deltaNorm += delta[j] * delta[j]; qNorm += q[j] * q[j]; }
                deltaNorm = Math.Sqrt(deltaNorm); qNorm = Math.Sqrt(qNorm);
                if (deltaNorm < xtol * (xtol + qNorm)) { success = true; message = "步长收敛（xtol）。"; stepAccepted = false; goto Done; }

                var qNew = (double[])q.Clone();
                for (int j = 0; j < m; j++) qNew[j] += delta[j];
                var rNew = residual(qNew);
                nfev++;
                double costNew = Dot(rNew, rNew);
                if (costNew < cost)
                {
                    double dCost = cost - costNew;
                    q = qNew; r = rNew; cost = costNew;
                    lambda = Math.Max(lambda / 3.0, 1e-12);
                    stepAccepted = true;
                    if (dCost < ftol * cost) { success = true; message = "代价收敛（ftol）。"; goto Done; }
                    break;
                }
                lambda *= 2.0;
            }
            if (!stepAccepted && !success) { success = true; message = "步长无法再降低代价，按收敛处理。"; break; }
        }
        if (nfev >= maxNfev && !success) message = "已达到最大函数求值次数（未收敛）。";

        Done:
        return new LmResult { X = q, Success = success, Nfev = nfev, Message = message };
    }

    private static double Dot(double[] a, double[] b)
    {
        double s = 0;
        for (int i = 0; i < a.Length; i++) s += a[i] * b[i];
        return s;
    }

    /// <summary>Cholesky 解对称正定方程 A·x = b；失败（非正定）返回 false。</summary>
    private static bool SolveSymmetric(double[,] a, double[] b, out double[] x)
    {
        int n = b.Length;
        x = new double[n];
        var l = new double[n, n];
        for (int i = 0; i < n; i++)
        {
            for (int j = 0; j <= i; j++)
            {
                double sum = a[i, j];
                for (int k = 0; k < j; k++) sum -= l[i, k] * l[j, k];
                if (i == j)
                {
                    if (sum <= 0) return false;
                    l[i, j] = Math.Sqrt(sum);
                }
                else l[i, j] = sum / l[j, j];
            }
        }
        var y = new double[n];
        for (int i = 0; i < n; i++)
        {
            double sum = b[i];
            for (int k = 0; k < i; k++) sum -= l[i, k] * y[k];
            y[i] = sum / l[i, i];
        }
        for (int i = n - 1; i >= 0; i--)
        {
            double sum = y[i];
            for (int k = i + 1; k < n; k++) sum -= l[k, i] * x[k];
            x[i] = sum / l[i, i];
        }
        return true;
    }

    /// <summary>
    /// 等价 PS Get-SpiralCandidate 的预筛选 + 拟合入口。
    /// 返回 null 表示不作为回旋线（按原始折线处理），诊断写入 diagnostics。
    /// </summary>
    public static SpiralCandidate? TryGetCandidate(
        List<Point2> points, SpiralMode mode, double toleranceM,
        double minSegLengthM, List<string> diagnostics, ref int fitAttemptCount)
    {
        if (points.Count < 20) return null;
        if (mode == SpiralMode.Off) return null;
        if (points.Count > Limits.MaxSpiralFitVertices)
        {
            diagnostics.Add($"高节点折线含 {points.Count} 个顶点，超过单段欧拉拟合性能上限 {Limits.MaxSpiralFitVertices}；为防止卡顿已按原始折线保真输入。");
            return null;
        }
        if (fitAttemptCount >= Limits.MaxSpiralFitCandidates)
        {
            diagnostics.Add($"本次导入已达到欧拉拟合安全上限 {Limits.MaxSpiralFitCandidates} 段；其余高节点折线按原始顶点保真输入。");
            return null;
        }

        var lengths = new List<double>();
        var headings = new List<double>();
        var stations = new List<double> { 0.0 };
        double total = 0.0;
        for (int i = 0; i < points.Count - 1; i++)
        {
            double d = Geometry.Distance(points[i], points[i + 1]);
            if (d < minSegLengthM) continue;
            total += d;
            lengths.Add(d);
            headings.Add(Geometry.Heading(points[i], points[i + 1]));
            stations.Add(total);
        }
        if (headings.Count < 12 || total <= 0) return null;

        var x = new List<double>();
        var y = new List<double>();
        for (int i = 1; i < headings.Count; i++)
        {
            double delta = Geometry.NormalizeAngle(headings[i] - headings[i - 1]);
            if (delta > Math.PI) delta -= Geometry.Tau;
            double ds = (lengths[i - 1] + lengths[i]) / 2.0;
            x.Add(stations[i]);
            y.Add(delta / ds);
        }
        if (x.Count < 10) return null;

        int n = x.Count;
        double sumX = x.Sum(), sumY = y.Sum(), sumXX = 0, sumXY = 0;
        for (int i = 0; i < n; i++) { sumXX += x[i] * x[i]; sumXY += x[i] * y[i]; }
        double den = n * sumXX - sumX * sumX;
        if (Math.Abs(den) < 1e-14) return null;
        double slope = (n * sumXY - sumX * sumY) / den;
        double intercept = (sumY - slope * sumX) / n;

        double meanY = sumY / n, ssRes = 0, ssTot = 0;
        for (int i = 0; i < n; i++)
        {
            double res = y[i] - (intercept + slope * x[i]);
            ssRes += res * res;
            double dev = y[i] - meanY;
            ssTot += dev * dev;
        }
        if (ssTot < 1e-18) return null;
        double r2 = 1.0 - ssRes / ssTot;
        double startK = intercept, endK = intercept + slope * total;
        var signs = y.Where(v => Math.Abs(v) > 1e-8).Select(Math.Sign).Distinct().ToArray();
        double span = Math.Abs(endK - startK);
        double curvatureScale = Math.Max(Math.Max(Math.Abs(startK), Math.Abs(endK)), 1e-6);
        bool preliminaryPass = r2 >= 0.999 && span >= 0.05 * curvatureScale && signs.Length == 1;
        if (!preliminaryPass && mode == SpiralMode.Strict) return null;
        if (!preliminaryPass && mode == SpiralMode.Loose)
            diagnostics.Add($"宽松欧拉判定：曲率预筛选未完全通过（R²={r2:F6}），继续执行 2 mm 拟合验收。");

        fitAttemptCount++;
        string modeText = mode == SpiralMode.Strict ? "严格 0.5 mm" : "宽松 2 mm";
        FitResult fit;
        try { fit = Fit(points, toleranceM); }
        catch (Exception ex)
        {
            diagnostics.Add($"欧拉回旋线{modeText}拟合失败：{ex.Message}，将按原始折线段保留。");
            return null;
        }
        if (!fit.StrictPass)
        {
            diagnostics.Add($"高节点折线未通过欧拉回旋线{modeText}验收：最大拟合偏差 {fit.MaxVertexErrorM * 1000.0:F3} mm（限值 ≤ {toleranceM * 1000.0:F3} mm），将按原始折线段保留。");
            return null;
        }
        return new SpiralCandidate
        {
            Length = fit.LengthM,
            StartHeading = Geometry.NormalizeAngle(fit.StartHeadingRad),
            EndHeading = Geometry.NormalizeAngle(fit.EndHeadingRad),
            StartCurvature = fit.StartRadiusM == 0 ? 0.0 : -1.0 / fit.StartRadiusM,
            EndCurvature = fit.EndRadiusM == 0 ? 0.0 : -1.0 / fit.EndRadiusM,
            Slope = slope,
            R2 = r2,
            FitMaxResidualM = fit.MaxVertexErrorM,
            FitToleranceM = toleranceM,
            FitMode = mode,
            Vertices = new List<Point2>(points)
        };
    }
}
