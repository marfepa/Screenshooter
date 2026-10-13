using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Threading;
using Screenshooter.Windows.Capture.Windows;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Core.Stitching;
using Screenshooter.Windows.Core.Storage;
using Screenshooter.Windows.Services;

namespace Screenshooter.Windows.Capture
{
    public sealed class ScrollCaptureSession : IDisposable
    {
        private readonly Rectangle _rect;
        private readonly Action<StripItem?> _onCompleted;
        private ScrollStitcher? _stitcher;
        private ScrollCapturePillWindow? _pillWindow;
        private DispatcherTimer? _captureTimer;
        private bool _isFinished;

        public ScrollCaptureSession(Rectangle rect, Action<StripItem?> onCompleted)
        {
            _rect = rect;
            _onCompleted = onCompleted;
        }

        public void Start()
        {
            // Tomar el primer fotograma
            using var firstFrame = ScreenCaptureEngine.Instance.CaptureArea(_rect);
            _stitcher = new ScrollStitcher(firstFrame);

            // Mostrar la píldora de control
            _pillWindow = new ScrollCapturePillWindow(_rect);
            _pillWindow.OnDoneClicked += Finish;
            _pillWindow.OnCancelClicked += Cancel;
            _pillWindow.Show();

            // Iniciar bucle de muestreo durante el scroll
            _captureTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(100)
            };
            _captureTimer.Tick += CaptureTimer_Tick;
            _captureTimer.Start();
        }

        private void CaptureTimer_Tick(object? sender, EventArgs e)
        {
            if (_isFinished || _stitcher == null) return;

            try
            {
                using var frame = ScreenCaptureEngine.Instance.CaptureArea(_rect);
                var outcome = _stitcher.Add(frame);
                if (outcome == ScrollStitcher.Outcome.Appended || outcome == ScrollStitcher.Outcome.LimitReached)
                {
                    _pillWindow?.UpdateProgress(_stitcher.Height, _stitcher.AcceptedFrameCount);
                    if (_stitcher.IsAtLimit)
                    {
                        Finish();
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[ScrollCaptureSession] Error capturando frame: {ex.Message}");
            }
        }

        public void Finish()
        {
            if (_isFinished) return;
            _isFinished = true;
            _captureTimer?.Stop();

            StripItem? resultItem = null;
            if (_stitcher != null)
            {
                using var finalImage = _stitcher.MakeImage();
                if (finalImage != null)
                {
                    string path = StripStorage.GenerateUniqueCapturePath("Captura larga");
                    finalImage.Save(path, ImageFormat.Png);
                    ClipboardService.CopyImage(path);

                    resultItem = new StripItem(path, finalImage.Width, finalImage.Height, isLongCapture: true);
                }
            }

            Dispose();
            _onCompleted(resultItem);
        }

        public void Cancel()
        {
            if (_isFinished) return;
            _isFinished = true;
            _captureTimer?.Stop();
            Dispose();
            _onCompleted(null);
        }

        public void Dispose()
        {
            _captureTimer?.Stop();
            _captureTimer = null;
            if (_pillWindow != null)
            {
                _pillWindow.Close();
                _pillWindow = null;
            }
        }
    }
}
