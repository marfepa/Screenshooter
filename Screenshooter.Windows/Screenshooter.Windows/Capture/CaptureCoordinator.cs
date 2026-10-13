using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Screenshooter.Windows.Capture.Windows;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Core.State;
using Screenshooter.Windows.Core.Storage;
using Screenshooter.Windows.Services;
using Screenshooter.Windows.Strip;
using Screenshooter.Windows.UI;
using Point = System.Windows.Point;

namespace Screenshooter.Windows.Capture
{
    public sealed class CaptureCoordinator
    {
        public static CaptureCoordinator Instance { get; } = new();

        public event Action? OnStateChanged;

        private ContinuousCaptureState _state = ContinuousCaptureState.Idle;
        public ContinuousCaptureState State => _state;
        public bool IsActive => _state != ContinuousCaptureState.Idle;

        private SelectionOverlayWindow? _overlayWindow;
        private NavigationPillWindow? _navigationPillWindow;
        private ScrollCaptureSession? _activeScrollSession;
        private readonly ScrollPassthroughTracker _passthroughTracker = new();
        private DispatcherTimer? _passthroughCheckTimer;

        private CaptureCoordinator() { }

        public void Initialize()
        {
            HotKeyManager.Instance.OnCaptureHotKey += ToggleCapture;
        }

        public void ToggleCapture()
        {
            if (_state == ContinuousCaptureState.Idle)
            {
                StartCapture();
            }
            else if (_state == ContinuousCaptureState.Selecting)
            {
                // Alternar a modo navegación
                Transition(ContinuousCaptureEvent.HotKey);
            }
            else if (_state == ContinuousCaptureState.Navigating)
            {
                // Volver a modo selección
                Transition(ContinuousCaptureEvent.HotKey);
            }
        }

        public void StartCapture()
        {
            if (_state != ContinuousCaptureState.Idle) return;
            Transition(ContinuousCaptureEvent.HotKey);
        }

        public void CancelCapture()
        {
            Transition(ContinuousCaptureEvent.Cancel);
        }

        private void Transition(ContinuousCaptureEvent evt)
        {
            var oldState = _state;
            _state = ContinuousCaptureMachine.Next(_state, evt);

            ApplyStateEffects(oldState, _state);
            OnStateChanged?.Invoke();
        }

        private void ApplyStateEffects(ContinuousCaptureState from, ContinuousCaptureState to)
        {
            switch (to)
            {
                case ContinuousCaptureState.Idle:
                    CloseOverlay();
                    CloseNavigationPill();
                    _activeScrollSession?.Cancel();
                    _activeScrollSession = null;
                    StopPassthroughTimer();
                    break;

                case ContinuousCaptureState.Selecting:
                    CloseNavigationPill();
                    StopPassthroughTimer();
                    EnsureOverlayVisible();
                    break;

                case ContinuousCaptureState.Navigating:
                    HideOverlay();
                    ShowNavigationPill();
                    break;

                case ContinuousCaptureState.ScrollPassthrough:
                    HideOverlay();
                    StartPassthroughTimer();
                    break;

                case ContinuousCaptureState.ScrollCapturing:
                    HideOverlay();
                    CloseNavigationPill();
                    break;

                case ContinuousCaptureState.Processing:
                    // Estado transitorio mientras se guarda la imagen
                    break;
            }
        }

        private void EnsureOverlayVisible()
        {
            if (_overlayWindow == null)
            {
                _overlayWindow = new SelectionOverlayWindow();
                _overlayWindow.OnAreaSelected += HandleAreaSelected;
                _overlayWindow.OnCancelRequested += CancelCapture;
                _overlayWindow.OnScrollBegan += HandleScrollBegan;
            }

            _overlayWindow.ResetSelection();
            _overlayWindow.Show();
            _overlayWindow.Activate();
        }

        private void HideOverlay()
        {
            if (_overlayWindow != null)
            {
                _overlayWindow.Hide();
            }
        }

        private void CloseOverlay()
        {
            if (_overlayWindow != null)
            {
                _overlayWindow.Close();
                _overlayWindow = null;
            }
        }

        private void ShowNavigationPill()
        {
            if (_navigationPillWindow == null)
            {
                _navigationPillWindow = new NavigationPillWindow();
                _navigationPillWindow.OnExitClicked += CancelCapture;
            }
            _navigationPillWindow.Show();
        }

        private void CloseNavigationPill()
        {
            if (_navigationPillWindow != null)
            {
                _navigationPillWindow.Close();
                _navigationPillWindow = null;
            }
        }

        private void HandleScrollBegan()
        {
            _passthroughTracker.NoteScroll(new Point(0, 0));
            Transition(ContinuousCaptureEvent.ScrollBegan);
        }

        private void StartPassthroughTimer()
        {
            StopPassthroughTimer();
            _passthroughCheckTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(100)
            };
            _passthroughCheckTimer.Tick += (s, e) =>
            {
                Interop.Win32.GetCursorPos(out var pt);
                if (_passthroughTracker.ShouldEnd(new Point(pt.X, pt.Y)))
                {
                    StopPassthroughTimer();
                    Transition(ContinuousCaptureEvent.ScrollEnded);
                }
            };
            _passthroughCheckTimer.Start();
        }

        private void StopPassthroughTimer()
        {
            if (_passthroughCheckTimer != null)
            {
                _passthroughCheckTimer.Stop();
                _passthroughCheckTimer = null;
            }
            _passthroughTracker.Reset();
        }

        private void HandleAreaSelected(Rectangle rect, bool isShiftHeld)
        {
            if (isShiftHeld)
            {
                // Iniciar captura larga
                Transition(ContinuousCaptureEvent.ScrollCaptureRequested);
                _activeScrollSession = new ScrollCaptureSession(rect, (resultItem) =>
                {
                    if (resultItem != null)
                    {
                        StripManager.Instance.Add(resultItem);
                        HUDNotificationWindow.ShowMessage("✓ Captura larga copiada");
                    }
                    Transition(ContinuousCaptureEvent.ScrollCaptureFinished);
                });
                _activeScrollSession.Start();
                return;
            }

            // Captura de área estándar
            Transition(ContinuousCaptureEvent.SelectionCompleted);

            try
            {
                using var bitmap = ScreenCaptureEngine.Instance.CaptureArea(rect);
                string path = StripStorage.GenerateUniqueCapturePath();
                bitmap.Save(path, ImageFormat.Png);

                ClipboardService.CopyImage(path);

                var item = new StripItem(path, bitmap.Width, bitmap.Height);
                StripManager.Instance.Add(item);

                HUDNotificationWindow.ShowMessage("✓ Copiado al portapapeles");
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[CaptureCoordinator] Error capturando: {ex.Message}");
            }

            // Modo continuo: seguir seleccionando
            Transition(ContinuousCaptureEvent.CaptureFinished);
        }

        public void StartScrollCaptureSelection()
        {
            StartCapture();
        }
    }
}
