using System;
using System.Windows.Interop;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.Services
{
    public sealed class HotKeyManager : IDisposable
    {
        public static HotKeyManager Instance { get; } = new();

        public const int HotKeyIdCapture = 9001;
        public const int HotKeyIdToggleStrip = 9002;

        public event Action? OnCaptureHotKey;
        public event Action? OnToggleStripHotKey;

        private HwndSource? _source;
        private IntPtr _hWnd;
        private bool _isDisposed;

        private HotKeyManager() { }

        public void Initialize()
        {
            var parameters = new HwndSourceParameters("Screenshooter_HotKeyHook")
            {
                Width = 0,
                Height = 0,
                PositionX = 0,
                PositionY = 0,
                WindowStyle = 0
            };

            _source = new HwndSource(parameters);
            _hWnd = _source.Handle;
            _source.AddHook(HwndHook);

            RegisterDefaults();
        }

        private void RegisterDefaults()
        {
            if (_hWnd == IntPtr.Zero) return;

            // Alt + Shift + S (VK_S = 0x53)
            Win32.RegisterHotKey(_hWnd, HotKeyIdCapture, Win32.MOD_ALT | Win32.MOD_SHIFT | Win32.MOD_NOREPEAT, 0x53);

            // Ctrl + Alt + T (VK_T = 0x54)
            Win32.RegisterHotKey(_hWnd, HotKeyIdToggleStrip, Win32.MOD_CONTROL | Win32.MOD_ALT | Win32.MOD_NOREPEAT, 0x54);
        }

        private IntPtr HwndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == Win32.WM_HOTKEY)
            {
                int id = wParam.ToInt32();
                if (id == HotKeyIdCapture)
                {
                    OnCaptureHotKey?.Invoke();
                    handled = true;
                }
                else if (id == HotKeyIdToggleStrip)
                {
                    OnToggleStripHotKey?.Invoke();
                    handled = true;
                }
            }
            return IntPtr.Zero;
        }

        public void Dispose()
        {
            if (_isDisposed) return;
            _isDisposed = true;

            if (_hWnd != IntPtr.Zero)
            {
                Win32.UnregisterHotKey(_hWnd, HotKeyIdCapture);
                Win32.UnregisterHotKey(_hWnd, HotKeyIdToggleStrip);
            }

            _source?.RemoveHook(HwndHook);
            _source?.Dispose();
        }
    }
}
