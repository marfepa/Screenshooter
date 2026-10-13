using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Forms;
using System.Windows.Input;
using System.Windows.Media;
using Screenshooter.Windows.Interop;
using Point = System.Windows.Point;

namespace Screenshooter.Windows.Capture.Windows
{
    public partial class SelectionOverlayWindow : Window
    {
        public event Action<Rectangle, bool>? OnAreaSelected; // rect, isShiftHeld
        public event Action? OnCancelRequested;
        public event Action? OnScrollBegan;

        private Point _startPoint;
        private bool _isSelecting;
        private System.Windows.Rect _currentRect;

        public SelectionOverlayWindow()
        {
            InitializeComponent();
            Loaded += SelectionOverlayWindow_Loaded;
        }

        private void SelectionOverlayWindow_Loaded(object sender, RoutedEventArgs e)
        {
            // Cubrir toda la pantalla virtual multimonitor
            var virtualScreen = SystemInformation.VirtualScreen;
            Left = virtualScreen.Left;
            Top = virtualScreen.Top;
            Width = virtualScreen.Width;
            Height = virtualScreen.Height;

            ResetSelection();
        }

        public void ResetSelection()
        {
            _isSelecting = false;
            _currentRect = System.Windows.Rect.Empty;
            SelectionBorder.Visibility = Visibility.Collapsed;
            DimensionPill.Visibility = Visibility.Collapsed;
            ShiftHintPill.Visibility = Visibility.Collapsed;

            // Máscara completa sobre la ventana
            var fullRect = new RectangleGeometry(new System.Windows.Rect(0, 0, Width, Height));
            MaskPath.Data = fullRect;
        }

        private void Window_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                _isSelecting = true;
                _startPoint = e.GetPosition(OverlayCanvas);
                _currentRect = new System.Windows.Rect(_startPoint, new System.Windows.Size(0, 0));
                UpdateSelectionVisuals();
            }
            else if (e.ChangedButton == MouseButton.Right)
            {
                // Clic derecho cancela la selección actual o sale
                if (_isSelecting)
                {
                    ResetSelection();
                }
                else
                {
                    OnCancelRequested?.Invoke();
                }
            }
        }

        private void Window_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
        {
            if (!_isSelecting) return;

            Point currentPoint = e.GetPosition(OverlayCanvas);
            double x = Math.Min(_startPoint.X, currentPoint.X);
            double y = Math.Min(_startPoint.Y, currentPoint.Y);
            double w = Math.Abs(currentPoint.X - _startPoint.X);
            double h = Math.Abs(currentPoint.Y - _startPoint.Y);

            _currentRect = new System.Windows.Rect(x, y, w, h);
            UpdateSelectionVisuals();
        }

        private void Window_MouseUp(object sender, MouseButtonEventArgs e)
        {
            if (!_isSelecting) return;
            _isSelecting = false;

            if (_currentRect.Width >= 4 && _currentRect.Height >= 4)
            {
                bool isShift = Keyboard.IsKeyDown(Key.LeftShift) || Keyboard.IsKeyDown(Key.RightShift);

                // Convertir coordenadas del canvas a coordenadas absolutas de pantalla
                int screenX = (int)Math.Round(Left + _currentRect.X);
                int screenY = (int)Math.Round(Top + _currentRect.Y);
                int screenW = (int)Math.Round(_currentRect.Width);
                int screenH = (int)Math.Round(_currentRect.Height);

                var rect = new Rectangle(screenX, screenY, screenW, screenH);
                ResetSelection();
                OnAreaSelected?.Invoke(rect, isShift);
            }
            else
            {
                ResetSelection();
            }
        }

        private void Window_MouseWheel(object sender, MouseWheelEventArgs e)
        {
            // El usuario está girando la rueda del ratón: apartar overlay para hacer scroll
            OnScrollBegan?.Invoke();
        }

        private void Window_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                ResetSelection();
                OnCancelRequested?.Invoke();
                e.Handled = true;
            }
        }

        private void UpdateSelectionVisuals()
        {
            if (_currentRect.IsEmpty || _currentRect.Width <= 0 || _currentRect.Height <= 0)
            {
                SelectionBorder.Visibility = Visibility.Collapsed;
                DimensionPill.Visibility = Visibility.Collapsed;
                ShiftHintPill.Visibility = Visibility.Collapsed;
                MaskPath.Data = new RectangleGeometry(new System.Windows.Rect(0, 0, Width, Height));
                return;
            }

            // 1. Posicionar borde
            SelectionBorder.Visibility = Visibility.Visible;
            Canvas.SetLeft(SelectionBorder, _currentRect.X);
            Canvas.SetTop(SelectionBorder, _currentRect.Y);
            SelectionBorder.Width = _currentRect.Width;
            SelectionBorder.Height = _currentRect.Height;

            // 2. Máscara con agujero transparente
            var fullGeom = new RectangleGeometry(new System.Windows.Rect(0, 0, Width, Height));
            var cutGeom = new RectangleGeometry(_currentRect);
            var combined = new CombinedGeometry(GeometryCombineMode.Exclude, fullGeom, cutGeom);
            MaskPath.Data = combined;

            // 3. Píldora de dimensiones
            DimensionPill.Visibility = Visibility.Visible;
            DimensionText.Text = $"{(int)_currentRect.Width} × {(int)_currentRect.Height}";

            double pillX = _currentRect.X + (_currentRect.Width / 2) - 35;
            double pillY = _currentRect.Y + _currentRect.Height + 8;
            if (pillY + 30 > Height) pillY = _currentRect.Y - 32;

            Canvas.SetLeft(DimensionPill, Math.Max(10, Math.Min(Width - 100, pillX)));
            Canvas.SetTop(DimensionPill, Math.Max(10, pillY));

            // 4. Indicador de shift si se mantiene pulsado
            bool isShift = Keyboard.IsKeyDown(Key.LeftShift) || Keyboard.IsKeyDown(Key.RightShift);
            if (isShift)
            {
                ShiftHintPill.Visibility = Visibility.Visible;
                Canvas.SetLeft(ShiftHintPill, Canvas.GetLeft(DimensionPill));
                Canvas.SetTop(ShiftHintPill, Canvas.GetTop(DimensionPill) + 26);
            }
            else
            {
                ShiftHintPill.Visibility = Visibility.Collapsed;
            }
        }
    }
}
