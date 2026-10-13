using System;
using System.Diagnostics;
using Microsoft.Win32;

namespace Screenshooter.Windows.Services
{
    public static class LaunchAtLoginManager
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string AppName = "Screenshooter";

        public static bool IsEnabled
        {
            get
            {
                try
                {
                    using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false);
                    return key?.GetValue(AppName) != null;
                }
                catch
                {
                    return false;
                }
            }
        }

        public static void SetEnabled(bool enable)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
                if (key == null) return;

                if (enable)
                {
                    string? exePath = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exePath))
                    {
                        key.SetValue(AppName, $"\"{exePath}\"");
                    }
                }
                else
                {
                    key.DeleteValue(AppName, false);
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[LaunchAtLoginManager] Error setting launch at login: {ex.Message}");
            }
        }

        public static void Toggle()
        {
            SetEnabled(!IsEnabled);
        }
    }
}
