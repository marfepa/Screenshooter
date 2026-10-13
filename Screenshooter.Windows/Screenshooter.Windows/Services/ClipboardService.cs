using System;
using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Screenshooter.Windows.Services
{
    public static class ClipboardService
    {
        public static bool CopyImage(string filePath)
        {
            if (!File.Exists(filePath)) return false;

            try
            {
                var dataObject = new DataObject();

                // 1. Añadir el archivo como DropList (para pegar en carpetas o explorador de archivos)
                var fileDropList = new StringCollection { filePath };
                dataObject.SetFileDropList(fileDropList);

                // 2. Añadir la imagen en memoria (para pegar en Slack, Word, Figma, navegadores)
                var bitmapImage = new BitmapImage();
                bitmapImage.BeginInit();
                bitmapImage.UriSource = new Uri(filePath, UriKind.Absolute);
                bitmapImage.CacheOption = BitmapCacheOption.OnLoad;
                bitmapImage.EndInit();
                bitmapImage.Freeze();
                dataObject.SetImage(bitmapImage);

                // 3. Formato PNG directo (algunas apps web prefieren PNG stream)
                using var fileStream = File.OpenRead(filePath);
                dataObject.SetData("PNG", fileStream);

                Clipboard.SetDataObject(dataObject, true);
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[ClipboardService] Error al copiar imagen: {ex.Message}");
                return false;
            }
        }

        public static bool CopyBitmap(Bitmap bitmap)
        {
            try
            {
                using var ms = new MemoryStream();
                bitmap.Save(ms, ImageFormat.Png);
                ms.Position = 0;

                var dataObject = new DataObject();
                dataObject.SetData("PNG", ms);

                var bitmapImage = new BitmapImage();
                bitmapImage.BeginInit();
                bitmapImage.StreamSource = ms;
                bitmapImage.CacheOption = BitmapCacheOption.OnLoad;
                bitmapImage.EndInit();
                bitmapImage.Freeze();
                dataObject.SetImage(bitmapImage);

                Clipboard.SetDataObject(dataObject, true);
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[ClipboardService] Error al copiar bitmap: {ex.Message}");
                return false;
            }
        }
    }
}
