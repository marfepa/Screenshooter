using System;
using System.Windows;
using System.Windows.Interop;

namespace Screenshooter.Windows.Interop
{
    public static class WindowExtensions
    {
        public static void MakeNonActivating(this Window window)
        {
            var helper = new WindowInteropHelper(window);
            var handle = helper.EnsureHandle();

            int exStyle = Win32.GetWindowLong(handle, Win32.GWL_EXSTYLE);
            exStyle |= Win32.WS_EX_NOACTIVATE | Win32.WS_EX_TOOLWINDOW;
            Win32.SetWindowLong(handle, Win32.GWL_EXSTYLE, exStyle);
        }

        public static void EnsureTopmost(this Window window)
        {
            var helper = new WindowInteropHelper(window);
            var handle = helper.EnsureHandle();
            Win32.SetWindowPos(handle, Win32.HWND_TOPMOST, 0, 0, 0, 0,
                Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
        }

        public static void SetClickThrough(this Window window, bool clickThrough)
        {
            var helper = new WindowInteropHelper(window);
            var handle = helper.EnsureHandle();

            int exStyle = Win32.GetWindowLong(handle, Win32.GWL_EXSTYLE);
            if (clickThrough)
            {
                exStyle |= Win32.WS_EX_TRANSPARENT;
            }
            else
            {
                exStyle &= ~Win32.WS_EX_TRANSPARENT;
            }
            Win32.SetWindowLong(handle, Win32.GWL_EXSTYLE, exStyle);
        }
    }
}
