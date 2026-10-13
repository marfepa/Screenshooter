using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Screenshooter.Windows.Strip.Controls
{
    public class RopeCanvas : Canvas
    {
        private readonly Pen _shadowPen;
        private readonly Pen _corePen;
        private readonly Pen _highlightPen;

        public RopeCanvas()
        {
            _shadowPen = new Pen(new SolidColorBrush(Color.FromArgb(80, 0, 0, 0)), 2.6)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round
            };
            _shadowPen.Freeze();

            _corePen = new Pen(new SolidColorBrush(Color.FromRgb(0x8A, 0x8A, 0x8E)), 1.8)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round
            };
            _corePen.Freeze();

            _highlightPen = new Pen(new SolidColorBrush(Color.FromArgb(100, 255, 255, 255)), 0.8)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round
            };
            _highlightPen.Freeze();
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);

            double w = ActualWidth;
            if (w <= 0) return;

            double sag = StripMotion.RopeSag(w);
            double y0 = StripMotion.RopeBase;

            // 1. Sombra difusa
            var shadowGeom = new PathGeometry();
            var shadowFig = new PathFigure
            {
                StartPoint = new Point(-20, y0 + 1.2),
                IsClosed = false
            };
            shadowFig.Segments.Add(new QuadraticBezierSegment(new Point(w / 2.0, y0 + 2 * sag + 1.2), new Point(w + 20, y0 + 1.2), true));
            shadowGeom.Figures.Add(shadowFig);
            dc.DrawGeometry(null, _shadowPen, shadowGeom);

            // 2. Núcleo de la cuerda
            var coreGeom = new PathGeometry();
            var coreFig = new PathFigure
            {
                StartPoint = new Point(-20, y0),
                IsClosed = false
            };
            coreFig.Segments.Add(new QuadraticBezierSegment(new Point(w / 2.0, y0 + 2 * sag), new Point(w + 20, y0), true));
            coreGeom.Figures.Add(coreFig);
            dc.DrawGeometry(null, _corePen, coreGeom);

            // 3. Brillo fino superior
            var highGeom = new PathGeometry();
            var highFig = new PathFigure
            {
                StartPoint = new Point(-20, y0 - 0.5),
                IsClosed = false
            };
            highFig.Segments.Add(new QuadraticBezierSegment(new Point(w / 2.0, y0 + 2 * sag - 0.5), new Point(w + 20, y0 - 0.5), true));
            highGeom.Figures.Add(highFig);
            dc.DrawGeometry(null, _highlightPen, highGeom);
        }
    }
}
