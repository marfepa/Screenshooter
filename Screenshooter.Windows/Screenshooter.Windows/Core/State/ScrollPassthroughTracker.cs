using System;
using System.Windows;

namespace Screenshooter.Windows.Core.State
{
    public class ScrollPassthroughTracker
    {
        public double QuietIntervalSeconds { get; }
        public double PointerTolerance { get; }
        public DateTime? LastScrollTime { get; private set; }
        public Point? Anchor { get; private set; }

        public ScrollPassthroughTracker(double quietIntervalSeconds = 1.2, double pointerTolerance = 6.0)
        {
            QuietIntervalSeconds = quietIntervalSeconds;
            PointerTolerance = pointerTolerance;
        }

        public void NoteScroll(Point pointer)
        {
            LastScrollTime = DateTime.UtcNow;
            Anchor = pointer;
        }

        public void Reset()
        {
            LastScrollTime = null;
            Anchor = null;
        }

        public bool ShouldEnd(Point currentPointer)
        {
            if (!LastScrollTime.HasValue || !Anchor.HasValue) return false;

            double dx = currentPointer.X - Anchor.Value.X;
            double dy = currentPointer.Y - Anchor.Value.Y;
            double dist = Math.Sqrt(dx * dx + dy * dy);

            if (dist > PointerTolerance)
            {
                return true;
            }

            return (DateTime.UtcNow - LastScrollTime.Value).TotalSeconds >= QuietIntervalSeconds;
        }
    }
}
