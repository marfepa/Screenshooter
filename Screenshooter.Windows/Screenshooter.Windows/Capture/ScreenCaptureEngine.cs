using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.Capture
{
    public sealed class ScreenCaptureEngine
    {
        public static ScreenCaptureEngine Instance { get; } = new();

        private ScreenCaptureEngine() { }

        /// <summary>
        /// Captura la pantalla virtual completa (todos los monitores combinados).
        /// </summary>
        public Bitmap CaptureVirtualScreen()
        {
            int left = SystemInformation.VirtualScreen.Left;
            int top = SystemInformation.VirtualScreen.Top;
            int width = SystemInformation.VirtualScreen.Width;
            int height = SystemInformation.VirtualScreen.Height;

            var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.CopyFromScreen(left, top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
            }
            return bitmap;
        }

        /// <summary>
        /// Captura un área específica en coordenadas absolutas de pantalla.
        /// </summary>
        public Bitmap CaptureArea(Rectangle screenBounds)
        {
            if (screenBounds.Width <= 0 || screenBounds.Height <= 0)
                throw new ArgumentException("El rectángulo de captura debe tener dimensiones mayores a cero.");

            var bitmap = new Bitmap(screenBounds.Width, screenBounds.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.CopyFromScreen(screenBounds.Left, screenBounds.Top, 0, 0, screenBounds.Size, CopyPixelOperation.SourceCopy);
            }
            return bitmap;
        }

        /// <summary>
        /// Captura usando GDI BitBlt con la bandera CAPTUREBLT para asegurar captura de ventanas transparentes.
        /// </summary>
        public Bitmap CaptureAreaWithGdi(Rectangle rect)
        {
            IntPtr hDesk = Win32.GetDesktopWindow();
            IntPtr hDeskDC = Win32.GetDC(hDesk);
            IntPtr hMemDC = Win32.CreateCompatibleDC(hDeskDC);
            IntPtr hBitmap = Win32.CreateCompatibleBitmap(hDeskDC, rect.Width, rect.Height);
            IntPtr hOld = Win32.SelectObject(hMemDC, hBitmap);

            Win32.BitBlt(hMemDC, 0, 0, rect.Width, rect.Height, hDeskDC, rect.Left, rect.Top, Win32.SRCCOPY | Win32.CAPTUREBLT);

            Bitmap bmp = Image.FromHbitmap(hBitmap);

            Win32.SelectObject(hMemDC, hOld);
            Win32.DeleteObject(hBitmap);
            Win32.DeleteDC(hMemDC);
            Win32.ReleaseDC(hDesk, hDeskDC);

            return bmp;
        }
    }
}
