using System;
using System.IO;
using System.Windows.Media.Imaging;

namespace Screenshooter.Windows.Core.Models
{
    public class StripItem : IEquatable<StripItem>
    {
        private static readonly Random Rnd = new Random();

        public Guid Id { get; }
        public string FilePath { get; set; }
        public int PixelWidth { get; set; }
        public int PixelHeight { get; set; }
        public double Tilt { get; set; }
        public DateTime CreatedAt { get; }
        public bool IsLongCapture { get; set; }
        public bool IsFlying { get; set; }

        private BitmapSource? _cachedThumbnail;

        public StripItem(
            string filePath,
            int pixelWidth,
            int pixelHeight,
            bool isLongCapture = false,
            double? tilt = null,
            DateTime? createdAt = null,
            Guid? id = null)
        {
            Id = id ?? Guid.NewGuid();
            FilePath = filePath;
            PixelWidth = pixelWidth;
            PixelHeight = pixelHeight;
            IsLongCapture = isLongCapture;
            Tilt = tilt ?? (Rnd.NextDouble() * 5.0 - 2.5); // -2.5° a +2.5°
            CreatedAt = createdAt ?? DateTime.Now;
        }

        public BitmapSource? GetThumbnail()
        {
            if (_cachedThumbnail != null) return _cachedThumbnail;
            if (!File.Exists(FilePath)) return null;

            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.UriSource = new Uri(FilePath, UriKind.Absolute);
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 320; // Optimización de memoria para la miniatura
                bitmap.EndInit();
                bitmap.Freeze();
                _cachedThumbnail = bitmap;
                return _cachedThumbnail;
            }
            catch
            {
                return null;
            }
        }

        public void ReloadFromDisk()
        {
            _cachedThumbnail = null;
            if (!File.Exists(FilePath)) return;

            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.UriSource = new Uri(FilePath, UriKind.Absolute);
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.EndInit();
                bitmap.Freeze();
                PixelWidth = bitmap.PixelWidth;
                PixelHeight = bitmap.PixelHeight;
            }
            catch { }
        }

        public string GetMetaText()
        {
            string timeStr = CreatedAt.ToString("HH:mm");
            string text = $"{timeStr} · {PixelWidth}×{PixelHeight}";
            if (IsLongCapture) text += " · captura larga";
            return text;
        }

        public bool Equals(StripItem? other)
        {
            if (other is null) return false;
            return Id == other.Id && IsFlying == other.IsFlying;
        }

        public override bool Equals(object? obj) => Equals(obj as StripItem);
        public override int GetHashCode() => Id.GetHashCode();
    }
}
