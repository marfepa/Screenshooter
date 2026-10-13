using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Screenshooter.Windows.Core.Stitching
{
    public sealed class ScrollStitcher
    {
        public sealed class Configuration
        {
            public int MaxHeight { get; set; } = 30_000;
            public int Downsample { get; set; } = 4;
            public int MinOverlapRows { get; set; } = 24;
            public double AcceptCost { get; set; } = 0.50;
            public double AmbiguityRatio { get; set; } = 1.5;
            public int MinDistinctRows { get; set; } = 8;
            public double UnchangedCost { get; set; } = 0.04;
            public double BandRowCost { get; set; } = 0.12;
        }

        public enum Outcome
        {
            Appended,
            Unchanged,
            NoOverlap,
            LimitReached
        }

        private sealed class Features
        {
            public byte[] Feat;
            public int[] Prof;
            public int[] Energy;
            public bool[] Distinct;

            public Features(int cols, int bands, int height)
            {
                Feat = new byte[cols * height];
                Prof = new int[bands * height];
                Energy = new int[height];
                Distinct = new bool[height];
            }
        }

        private readonly Configuration _config;
        private readonly int _width;
        private readonly int _frameHeight;
        private readonly int _rowBytes;
        private readonly int _cols;
        private readonly int _bands;
        private readonly int[] _bandEdges;

        private List<byte> _canvas = new();
        private int _canvasRows;
        private byte[] _footer = Array.Empty<byte>();
        private int _footerRows => _footer.Length / Math.Max(_rowBytes, 1);
        private bool _bandsFixed;

        private Features _ref;
        private Features _new;
        private byte[] _luma;
        private byte[] _pixels;
        private int _refTop;

        private const int NoiseFloor = 12;
        private const double IgnoredRightFraction = 0.02;
        private const int PoolRows = 4;
        private const int MaxCandidates = 5;
        private const int FamilyWindow = 32;
        private const int SeamStripRows = 80;
        private static readonly double[] StripFractions = { 0.1, 0.3 };
        private const int SeamWindow = 32;
        private const int MinBandDistinctRows = 6;

        public int Width => _width;
        public int Height => _canvasRows + _footerRows;
        public bool IsAtLimit { get; private set; }
        public int FixedTopRows { get; private set; }
        public int FixedBottomRows { get; private set; }
        public int AcceptedFrameCount { get; private set; } = 1;

        public ScrollStitcher(Bitmap firstFrame, Configuration? config = null)
        {
            _config = config ?? new Configuration();
            _width = firstFrame.Width;
            _frameHeight = firstFrame.Height;
            _rowBytes = _width * 4;

            int usable = _width - (int)Math.Round(_width * IgnoredRightFraction);
            _cols = Math.Max(2, Math.Min(_width, usable / Math.Max(1, _config.Downsample)));
            _bands = Math.Min(16, _cols);

            _bandEdges = new int[_bands + 1];
            for (int i = 0; i <= _bands; i++)
            {
                _bandEdges[i] = i * _cols / _bands;
            }

            _pixels = new byte[_width * _frameHeight * 4];
            _luma = new byte[_cols * _frameHeight];
            _ref = new Features(_cols, _bands, _frameHeight);
            _new = new Features(_cols, _bands, _frameHeight);

            RenderBitmap(firstFrame);
            ComputeFeatures(_ref);

            _canvas.AddRange(_pixels);
            _canvasRows = _frameHeight;
            IsAtLimit = Height >= _config.MaxHeight;
        }

        public Outcome Add(Bitmap frame)
        {
            if (IsAtLimit) return Outcome.LimitReached;
            if (frame.Width != _width || frame.Height != _frameHeight) return Outcome.NoOverlap;

            RenderBitmap(frame);
            ComputeFeatures(_new);

            int top = FixedTopRows;
            int bottom = FixedBottomRows;
            int n0 = _frameHeight - top - bottom;

            if (!HasDistinctRows(top, bottom)) return Outcome.Unchanged;

            var (zeroCost, zeroRows) = Cost(0, top, n0, 2, 2);
            if (zeroRows > 0 && zeroCost < _config.UnchangedCost)
            {
                return Outcome.Unchanged;
            }

            int d;
            if (_bandsFixed)
            {
                int? found = Locate(top, bottom);
                if (!found.HasValue) return Outcome.NoOverlap;
                d = found.Value;
            }
            else
            {
                var attempt = DetectBands();
                int? result = Locate(attempt.top, attempt.bottom);
                if (!result.HasValue && (attempt.top > 0 || attempt.bottom > 0))
                {
                    attempt = (0, 0);
                    result = Locate(0, 0);
                }
                if (!result.HasValue) return Outcome.NoOverlap;
                if (result.Value == 0) return Outcome.Unchanged;

                d = result.Value;
                top = attempt.top;
                bottom = attempt.bottom;
                _bandsFixed = true;
                FixedTopRows = top;
                FixedBottomRows = bottom;

                if (bottom > 0 && _canvasRows >= bottom)
                {
                    int cut = (_canvasRows - bottom) * _rowBytes;
                    int count = _canvas.Count - cut;
                    _footer = new byte[count];
                    _canvas.CopyTo(cut, _footer, 0, count);
                    _canvas.RemoveRange(cut, count);
                    _canvasRows -= bottom;
                }
                _refTop = top;
            }

            int contentH = _frameHeight - top - bottom;
            int newTop = _refTop + d;
            int overhang = Math.Min(Math.Max(0, newTop + contentH - _canvasRows), contentH);
            int allowed = Math.Max(0, _config.MaxHeight - Height);
            int rowsToAdd = Math.Min(overhang, allowed);

            if (rowsToAdd > 0)
            {
                int start = (top + contentH - overhang) * _rowBytes;
                int bytesToAdd = rowsToAdd * _rowBytes;
                byte[] chunk = new byte[bytesToAdd];
                Array.Copy(_pixels, start, chunk, 0, bytesToAdd);
                _canvas.AddRange(chunk);
                _canvasRows += rowsToAdd;
            }

            // Swap features
            (_ref, _new) = (_new, _ref);
            _refTop = newTop;

            if (rowsToAdd < overhang)
            {
                IsAtLimit = true;
                if (rowsToAdd > 0) AcceptedFrameCount++;
                return Outcome.LimitReached;
            }

            if (rowsToAdd > 0)
            {
                AcceptedFrameCount++;
                if (Height >= _config.MaxHeight) IsAtLimit = true;
                return Outcome.Appended;
            }

            return Outcome.Unchanged;
        }

        public Bitmap? MakeImage()
        {
            if (Height <= 0 || _width <= 0) return null;

            byte[] fullData = new byte[_canvas.Count + _footer.Length];
            _canvas.CopyTo(fullData, 0);
            if (_footer.Length > 0)
            {
                Array.Copy(_footer, 0, fullData, _canvas.Count, _footer.Length);
            }

            var bmp = new Bitmap(_width, Height, PixelFormat.Format32bppArgb);
            var rect = new Rectangle(0, 0, _width, Height);
            var bmpData = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(fullData, 0, bmpData.Scan0, fullData.Length);
            bmp.UnlockBits(bmpData);
            return bmp;
        }

        private void RenderBitmap(Bitmap frame)
        {
            var rect = new Rectangle(0, 0, _width, _frameHeight);
            var data = frame.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            Marshal.Copy(data.Scan0, _pixels, 0, _pixels.Length);
            frame.UnlockBits(data);
        }

        private void ComputeFeatures(Features f)
        {
            int step = _config.Downsample * 4;
            int distinctEnergy = _cols;

            for (int y = 0; y < _frameHeight; y++)
            {
                int rowOff = y * _rowBytes;
                int outOff = y * _cols;
                for (int c = 0; c < _cols; c++)
                {
                    int p = rowOff + c * step;
                    // Formula sRGB: B=0, G=1, R=2
                    _luma[outOff + c] = (byte)((_pixels[p + 2] * 77 + _pixels[p + 1] * 150 + _pixels[p] * 29) >> 8);
                }
            }

            for (int y = 0; y < _frameHeight; y++)
            {
                int lOff = y * _cols;
                int lnOff = (y + 1 < _frameHeight) ? (y + 1) * _cols : lOff;
                int frOff = y * _cols;
                int prOff = y * _bands;
                int total = 0;

                for (int b = 0; b < _bands; b++)
                {
                    int s = 0;
                    int cStart = _bandEdges[b];
                    int cEnd = _bandEdges[b + 1];
                    for (int c = cStart; c < cEnd; c++)
                    {
                        int cur = _luma[lOff + c];
                        int dx = (c + 1 < _cols) ? Math.Abs(_luma[lOff + c + 1] - cur) : 0;
                        int dy = Math.Abs(_luma[lnOff + c] - cur);
                        int g = Math.Clamp(dx + dy - NoiseFloor, 0, 255);
                        f.Feat[frOff + c] = (byte)g;
                        s += g;
                    }
                    f.Prof[prOff + b] = s;
                    total += s;
                }
                f.Energy[y] = total;
                f.Distinct[y] = total >= distinctEnergy;
            }
        }

        private (double cost, int rows) Cost(int shift, int top, int count, int rowStep, int colStep, int? strip = null)
        {
            var (lo, hi) = GetOverlap(shift, count, strip);
            if (hi <= lo) return (1.0, 0);

            long sad = 0;
            long sum = 0;
            int rows = 0;

            for (int i = lo; i < hi; i += rowStep)
            {
                int a = top + i;
                int b = top + i + shift;
                if (_new.Distinct[a] || _ref.Distinct[b])
                {
                    int pa = a * _cols;
                    int pb = b * _cols;
                    int pu = b > 0 ? (b - 1) * _cols : pb;
                    int pd = (b + 1 < _frameHeight) ? (b + 1) * _cols : pb;

                    for (int c = 0; c < _cols; c += colStep)
                    {
                        int x = _new.Feat[pa + c];
                        int yVal = _ref.Feat[pb + c];
                        int diff = Math.Abs(x - yVal);
                        int u = _ref.Feat[pu + c];
                        int v = _ref.Feat[pd + c];
                        int du = Math.Abs(x - u);
                        int dv = Math.Abs(x - v);
                        if (du < diff) diff = du;
                        if (dv < diff) diff = dv;
                        sad += diff;
                        sum += x + yVal;
                    }
                    rows++;
                }
            }

            return (sum > 0 ? (double)sad / sum : 1.0, rows);
        }

        private (int top, int bottom) DetectBands()
        {
            int h = _frameHeight;
            int cap = (int)(h * 0.4);

            int top = 0;
            while (top < cap && IsRowMatch(top) >= 0) top++;
            if (top > 0 && top < cap) top++;
            while (top > 0 && !_ref.Distinct[top - 1]) top--;
            if (CountDistinctRows(0, top) < MinBandDistinctRows) top = 0;

            int bottom = 0;
            while (bottom < cap && IsRowMatch(h - 1 - bottom) >= 0) bottom++;
            while (bottom > 0 && !_ref.Distinct[h - bottom]) bottom--;
            if (CountDistinctRows(h - bottom, h) < MinBandDistinctRows) bottom = 0;

            return (top, bottom);

            int IsRowMatch(int y)
            {
                if (!_ref.Distinct[y] && !_new.Distinct[y]) return 0;
                var (c, _) = RowCost(y);
                return c <= _config.BandRowCost ? 1 : -1;
            }
        }

        private (double cost, int sum) RowCost(int y)
        {
            int pa = y * _cols;
            long sad = 0;
            long sum = 0;
            for (int c = 0; c < _cols; c++)
            {
                int x = _new.Feat[pa + c];
                int v = _ref.Feat[pa + c];
                sad += Math.Abs(x - v);
                sum += x + v;
            }
            return (sum > 0 ? (double)sad / sum : 1.0, (int)sum);
        }

        private int CountDistinctRows(int start, int end)
        {
            int n = 0;
            for (int y = start; y < end; y++)
            {
                if (_ref.Distinct[y]) n++;
            }
            return n;
        }

        private (int lo, int hi) GetOverlap(int shift, int count, int? strip)
        {
            int lo = Math.Max(0, -shift);
            int hi = Math.Min(count, count - shift);
            if (strip.HasValue)
            {
                lo = Math.Max(lo, count - strip.Value - shift);
            }
            return (lo, hi);
        }

        private bool HasDistinctRows(int top, int bottom)
        {
            for (int i = top; i < (_frameHeight - bottom); i++)
            {
                if (_new.Distinct[i] || _ref.Distinct[i]) return true;
            }
            return false;
        }

        private int? Locate(int top, int bottom)
        {
            int n = _frameHeight - top - bottom;
            foreach (double fraction in StripFractions)
            {
                int strip = Math.Max(_config.MinOverlapRows * 2, (int)(n * fraction));
                if (strip < n)
                {
                    int? found = Search(top, bottom, strip);
                    if (found.HasValue)
                    {
                        return RefineAtSeam(found.Value, top, n) ?? found.Value;
                    }
                }
            }

            int? globalFound = Search(top, bottom);
            if (!globalFound.HasValue) return null;
            return RefineAtSeam(globalFound.Value, top, n);
        }

        private int? Search(int top, int bottom, int? strip = null)
        {
            int n = _frameHeight - top - bottom;
            int minOverlap = Math.Max(1, _config.MinOverlapRows);
            if (n < minOverlap) return null;
            if (!HasDistinctRows(top, bottom)) return null;

            int maxD = n - minOverlap;
            int R = n / PoolRows;
            int kMax = Math.Min(maxD / PoolRows, R - (minOverlap + PoolRows - 1) / PoolRows);
            if (R < 2 || kMax < 0) return null;

            int[] pn = new int[R * _bands];
            int[] pr = new int[R * _bands];
            int[] sn = new int[R + 1];
            int[] sr = new int[R + 1];

            for (int r = 0; r < R; r++)
            {
                for (int j = 0; j < PoolRows; j++)
                {
                    int y = top + r * PoolRows + j;
                    for (int b = 0; b < _bands; b++)
                    {
                        pn[r * _bands + b] += _new.Prof[y * _bands + b];
                        pr[r * _bands + b] += _ref.Prof[y * _bands + b];
                    }
                    sn[r + 1] += _new.Energy[y];
                    sr[r + 1] += _ref.Energy[y];
                }
            }
            for (int r = 0; r < R; r++)
            {
                sn[r + 1] += sn[r];
                sr[r + 1] += sr[r];
            }

            double[] coarse = new double[2 * kMax + 1];
            Array.Fill(coarse, 2.0);

            for (int k = -kMax; k <= kMax; k++)
            {
                int lo = Math.Max(0, -k);
                int hi = Math.Min(R, R - k);
                if (strip.HasValue) lo = Math.Max(lo, (n - strip.Value) / PoolRows - k);
                if (hi <= lo) continue;

                long sad = 0;
                for (int row = lo; row < hi; row++)
                {
                    int pa = row * _bands;
                    int pb = (row + k) * _bands;
                    for (int b = 0; b < _bands; b++)
                    {
                        sad += Math.Abs(pn[pa + b] - pr[pb + b]);
                    }
                }
                long den = (sn[hi] - sn[lo]) + (sr[hi + k] - sr[lo + k]);
                coarse[k + kMax] = den > 0 ? (double)sad / den : 1.0;
            }

            var minima = new List<(int k, double c)>();
            for (int i = 0; i < coarse.Length; i++)
            {
                if (coarse[i] < 1.0)
                {
                    double left = i > 0 ? coarse[i - 1] : 3;
                    double right = i + 1 < coarse.Length ? coarse[i + 1] : 3;
                    if (coarse[i] <= left && coarse[i] <= right)
                    {
                        minima.Add((i - kMax, coarse[i]));
                    }
                }
            }
            minima.Sort((a, b) => a.c.CompareTo(b.c));
            if (minima.Count > MaxCandidates) minima.RemoveRange(MaxCandidates, minima.Count - MaxCandidates);
            if (minima.Count == 0) return null;

            var results = new List<(int d, double cost, int rows)>();
            foreach (var m in minima)
            {
                int bestD = m.k * PoolRows;
                double bestC = double.PositiveInfinity;
                for (int d = m.k * PoolRows - PoolRows - 1; d <= m.k * PoolRows + PoolRows + 1; d++)
                {
                    if (Math.Abs(d) <= maxD)
                    {
                        double c = ProfileCost(d, top, n, strip);
                        if (c < bestC) { bestC = c; bestD = d; }
                    }
                }
                if (!double.IsFinite(bestC)) continue;

                var (fullCost, fullRows) = Cost(bestD, top, n, 2, 2, strip);
                int idx = results.FindIndex(r => Math.Abs(r.d - bestD) <= FamilyWindow);
                if (idx >= 0)
                {
                    if (fullCost < results[idx].cost) results[idx] = (bestD, fullCost, fullRows);
                }
                else
                {
                    results.Add((bestD, fullCost, fullRows));
                }
            }
            results.Sort((a, b) => a.cost.CompareTo(b.cost));
            if (results.Count == 0) return null;

            var best = results[0];
            var second = results.Count > 1 ? results[1] : default;

            var (ovLo, ovHi) = GetOverlap(best.d, n, strip);
            int overlapRows = Math.Max(0, ovHi - ovLo);

            if (best.cost >= _config.AcceptCost || overlapRows < minOverlap ||
                best.rows < Math.Min(_config.MinDistinctRows, Math.Max(1, minOverlap / 2)))
            {
                return null;
            }

            if (results.Count > 1 && second.cost < _config.AmbiguityRatio * Math.Max(best.cost, 0.02))
            {
                return null;
            }

            return best.d;
        }

        private double ProfileCost(int shift, int top, int count, int? strip)
        {
            var (lo, hi) = GetOverlap(shift, count, strip);
            if (hi <= lo) return double.PositiveInfinity;

            long sad = 0;
            long sum = 0;
            for (int i = lo; i < hi; i++)
            {
                int a = top + i;
                int b = top + i + shift;
                int pa = a * _bands;
                int pb = b * _bands;
                for (int k = 0; k < _bands; k++)
                {
                    sad += Math.Abs(_new.Prof[pa + k] - _ref.Prof[pb + k]);
                }
                sum += _new.Energy[a] + _ref.Energy[b];
            }
            return sum > 0 ? (double)sad / sum : 1.0;
        }

        private int? RefineAtSeam(int d, int top, int n)
        {
            if (d <= 0) return d;
            int seam = n - d;
            int first = Math.Max(0, seam - SeamStripRows);
            if (seam - first < _config.MinOverlapRows) return d;

            int bestE = d;
            double bestC = double.PositiveInfinity;
            int startE = Math.Max(1, d - SeamWindow);
            int endE = Math.Min(n - _config.MinOverlapRows, d + SeamWindow);

            for (int e = startE; e <= endE; e++)
            {
                int hi = Math.Min(seam, n - e);
                if (hi - first < _config.MinOverlapRows) continue;

                double c = ProfileCost(e, top, n, null);
                if (c < bestC - 1e-9 || (Math.Abs(c - bestC) <= 1e-9 && Math.Abs(e - d) < Math.Abs(bestE - d)))
                {
                    bestC = c;
                    bestE = e;
                }
            }

            if (bestC >= 1.0) return d;
            return bestC < _config.AcceptCost ? bestE : null;
        }
    }
}
