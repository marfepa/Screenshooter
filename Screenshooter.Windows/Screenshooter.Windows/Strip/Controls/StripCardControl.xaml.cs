using System;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Services;
using Screenshooter.Windows.UI;
using Point = System.Windows.Point;

namespace Screenshooter.Windows.Strip.Controls
{
    public partial class StripCardControl : System.Windows.Controls.UserControl
    {
        public StripItem Item { get; }
        public event Action<StripCardControl>? OnDismissRequested;

        private Point _dragStartPoint;
        private bool _isDragging;

        public StripCardControl(StripItem item)
        {
            InitializeComponent();
            Item = item;

            CardRotate.Angle = item.Tilt;
            MetaTextBlock.Text = item.GetMetaText();

            if (item.IsLongCapture)
            {
                LongCaptureGradient.Visibility = Visibility.Visible;
            }

            var thumb = item.GetThumbnail();
            if (thumb != null)
            {
                ThumbnailImage.Source = thumb;
            }
        }

        private void UserControl_MouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
        {
            HoverOverlay.Visibility = Visibility.Visible;
            Panel.SetZIndex(this, 100);

            // Animación suave de escala al pasar el ratón (1.035x)
            var scaleAnim = new DoubleAnimation(1.035, TimeSpan.FromMilliseconds(180))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            CardScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleXProperty, scaleAnim);
            CardScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleYProperty, scaleAnim);
        }

        private void UserControl_MouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
        {
            HoverOverlay.Visibility = Visibility.Collapsed;
            Panel.SetZIndex(this, 0);

            var scaleAnim = new DoubleAnimation(1.0, TimeSpan.FromMilliseconds(180))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            CardScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleXProperty, scaleAnim);
            CardScale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleYProperty, scaleAnim);
        }

        private void UserControl_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                _dragStartPoint = e.GetPosition(this);
                _isDragging = false;

                if (e.ClickCount == 2)
                {
                    // Doble clic: abrir en visor
                    OpenInDefaultViewer();
                    e.Handled = true;
                }
            }
        }

        private void UserControl_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
        {
            if (e.LeftButton == MouseButtonState.Pressed && !_isDragging)
            {
                Point current = e.GetPosition(this);
                double diffX = Math.Abs(current.X - _dragStartPoint.X);
                double diffY = Math.Abs(current.Y - _dragStartPoint.Y);

                if (diffX > 6 || diffY > 6)
                {
                    _isDragging = true;
                    StartDragDrop();
                }
            }
        }

        private void StartDragDrop()
        {
            if (!File.Exists(Item.FilePath)) return;

            var dataObject = new DataObject();
            var files = new System.Collections.Specialized.StringCollection { Item.FilePath };
            dataObject.SetFileDropList(files);

            var thumb = Item.GetThumbnail();
            if (thumb != null)
            {
                dataObject.SetImage(thumb);
            }

            DragDrop.DoDragDrop(this, dataObject, DragDropEffects.Copy);
            _isDragging = false;
        }

        public void CopyToClipboard()
        {
            if (ClipboardService.CopyImage(Item.FilePath))
            {
                HUDNotificationWindow.ShowMessage("✓ Copiado al portapapeles");
            }
        }

        public void OpenInDefaultViewer()
        {
            if (!File.Exists(Item.FilePath)) return;
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Item.FilePath,
                    UseShellExecute = true
                });
            }
            catch { }
        }

        public void OpenInPaint()
        {
            if (!File.Exists(Item.FilePath)) return;
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "mspaint.exe",
                    Arguments = $"\"{Item.FilePath}\"",
                    UseShellExecute = true
                });
            }
            catch { }
        }

        public void ShowInExplorer()
        {
            if (!File.Exists(Item.FilePath)) return;
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{Item.FilePath}\"",
                    UseShellExecute = true
                });
            }
            catch { }
        }

        public void AnimateFallAndDismiss()
        {
            // Animación física de descarte: cae hacia abajo girando
            var fallAnim = new DoubleAnimation(180, TimeSpan.FromMilliseconds(350))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
            };
            var rotAnim = new DoubleAnimation(Item.Tilt + 24, TimeSpan.FromMilliseconds(350));
            var fadeAnim = new DoubleAnimation(0, TimeSpan.FromMilliseconds(300));

            fallAnim.Completed += (s, e) =>
            {
                OnDismissRequested?.Invoke(this);
            };

            CardTranslate.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, fallAnim);
            CardRotate.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty, rotAnim);
            BeginAnimation(OpacityProperty, fadeAnim);
        }

        private void CopyButton_Click(object sender, RoutedEventArgs e)
        {
            CopyToClipboard();
            e.Handled = true;
        }

        private void OpenButton_Click(object sender, RoutedEventArgs e)
        {
            OpenInDefaultViewer();
            e.Handled = true;
        }

        private void DismissButton_Click(object sender, RoutedEventArgs e)
        {
            AnimateFallAndDismiss();
            e.Handled = true;
        }

        private void MenuCopy_Click(object sender, RoutedEventArgs e) => CopyToClipboard();
        private void MenuOpen_Click(object sender, RoutedEventArgs e) => OpenInDefaultViewer();
        private void MenuOpenPaint_Click(object sender, RoutedEventArgs e) => OpenInPaint();
        private void MenuShowInExplorer_Click(object sender, RoutedEventArgs e) => ShowInExplorer();
        private void MenuDelete_Click(object sender, RoutedEventArgs e) => AnimateFallAndDismiss();
    }
}
