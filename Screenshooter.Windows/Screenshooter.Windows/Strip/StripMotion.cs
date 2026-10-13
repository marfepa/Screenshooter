using System;
using System.Collections.Generic;
using System.Windows;

namespace Screenshooter.Windows.Strip
{
    public static class StripMotion
    {
        public const double StripHeight = 180.0;
        public const double CardWidth = 150.0;
        public const double CardHeight = 104.0;
        public const double SlotWidth = 150.0;
        public const double SlotHeight = 146.0;
        public const double CardTopInset = 8.0;
        public const double Gap = 14.0;
        public const double MinLeading = 24.0;
        public const double RopeBase = 14.0;
        public const double SlotTopBase = 16.0;

        public static double RopeSag(double width)
        {
            return Math.Max(0, Math.Min(12, width / 120.0));
        }

        public static double RopeY(double x, double width)
        {
            if (width <= 0) return 0;
            double t = Math.Clamp(x / width, 0.0, 1.0);
            return 4.0 * RopeSag(width) * t * (1.0 - t);
        }

        public static List<Rect> CardFrames(int count, double width)
        {
            var frames = new List<Rect>();
            if (count <= 0 || width <= 0) return frames;

            double total = count * SlotWidth + (count - 1) * Gap;
            double x = Math.Max(MinLeading, (width - total) / 2.0);

            for (int i = 0; i < count; i++)
            {
                double y = SlotTopBase + RopeY(x + SlotWidth / 2.0, width);
                frames.Add(new Rect(x, y, SlotWidth, SlotHeight));
                x += SlotWidth + Gap;
            }

            return frames;
        }
    }
}
