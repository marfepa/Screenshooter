using System;
using System.IO;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Core.Storage;

namespace Screenshooter.Windows.Services
{
    public sealed class InboxManager : IDisposable
    {
        public static InboxManager Instance { get; } = new();

        public event Action<StripItem>? OnScreenshotImported;

        private FileSystemWatcher? _watcher;
        private bool _isEnabled;

        public bool IsEnabled
        {
            get => _isEnabled;
            set
            {
                if (_isEnabled == value) return;
                _isEnabled = value;
                if (_isEnabled) StartWatching();
                else StopWatching();
            }
        }

        private InboxManager() { }

        private void StartWatching()
        {
            StopWatching();

            string userPictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
            string screenshotsDir = Path.Combine(userPictures, "Screenshots");

            if (!Directory.Exists(screenshotsDir))
            {
                try { Directory.CreateDirectory(screenshotsDir); }
                catch { return; }
            }

            _watcher = new FileSystemWatcher(screenshotsDir)
            {
                Filter = "*.png",
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite,
                EnableRaisingEvents = true
            };

            _watcher.Created += Watcher_Created;
        }

        private void StopWatching()
        {
            if (_watcher != null)
            {
                _watcher.EnableRaisingEvents = false;
                _watcher.Created -= Watcher_Created;
                _watcher.Dispose();
                _watcher = null;
            }
        }

        private async void Watcher_Created(object sender, FileSystemEventArgs e)
        {
            try
            {
                // Esperar un instante para que el archivo termine de escribirse
                await System.Threading.Tasks.Task.Delay(300);

                if (!File.Exists(e.FullPath)) return;

                // Copiar a la carpeta Inbox de la Tira
                string destination = StripStorage.GenerateUniqueCapturePath("Captura Windows", isInbox: true);
                File.Copy(e.FullPath, destination, true);

                int width = 0;
                int height = 0;
                using (var bmp = new System.Drawing.Bitmap(destination))
                {
                    width = bmp.Width;
                    height = bmp.Height;
                }

                var item = new StripItem(destination, width, height, isLongCapture: false);
                System.Windows.Application.Current.Dispatcher.Invoke(() =>
                {
                    OnScreenshotImported?.Invoke(item);
                });
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[InboxManager] Error importando captura: {ex.Message}");
            }
        }

        public void Dispose()
        {
            StopWatching();
        }
    }
}
