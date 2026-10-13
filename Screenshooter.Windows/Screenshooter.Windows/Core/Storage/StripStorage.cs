using System;
using System.IO;

namespace Screenshooter.Windows.Core.Storage
{
    public static class StripStorage
    {
        private static readonly string RootFolderName = "Screenshooter";
        private static readonly string ShelfFolderName = "Shelf";
        private static readonly string InboxFolderName = "Inbox";

        public static string GetBaseDirectory()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(appData, RootFolderName);
        }

        public static string GetShelfDirectory()
        {
            string dir = Path.Combine(GetBaseDirectory(), ShelfFolderName);
            if (!Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }
            return dir;
        }

        public static string GetInboxDirectory()
        {
            string dir = Path.Combine(GetShelfDirectory(), InboxFolderName);
            if (!Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }
            return dir;
        }

        public static string GenerateUniqueCapturePath(string? prefix = null, bool isInbox = false)
        {
            string targetDir = isInbox ? GetInboxDirectory() : GetShelfDirectory();
            string pfx = prefix ?? "Captura";
            string timestamp = DateTime.Now.ToString("yyyy-MM-dd 'a las' HH.mm.ss");
            string baseFileName = $"{pfx} {timestamp}";
            string fullPath = Path.Combine(targetDir, $"{baseFileName}.png");

            int counter = 1;
            while (File.Exists(fullPath))
            {
                fullPath = Path.Combine(targetDir, $"{baseFileName} ({counter}).png");
                counter++;
            }

            return fullPath;
        }

        public static void OpenFolderInExplorer()
        {
            string dir = GetShelfDirectory();
            if (Directory.Exists(dir))
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = dir,
                    UseShellExecute = true
                });
            }
        }
    }
}
