using System;
using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Input;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.Capture.Windows
{
    public partial class ScrollCapturePillWindow : Window
    {
        public event Action? OnDoneClicked;
        public event Action? OnCancelClicked;

        private readonly Rectangle _captureArea;

        public ScrollCapturePillWindow(Rectangle captureArea)
        {
            InitializeComponent();
            _captureArea = captureArea;
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            this.MakeNonActivating();

            // Posicionar la píldora centrada sobre el área de captura o encima de ella
            Left = _captureArea.Left + (_captureArea.Width - ActualWidth) / 2;
            Top = Math.Max(20, _captureArea.Top - ActualHeight - 12);

            // Si se sale de la pantalla, posicionar dentro
            var primary = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
            if (Top < primary.Top + 10) Top = _captureArea.Top + 10;
        }

        public void UpdateProgress(int height, int frames)
        {
            StatusText.Text = $"{height} px cosidos · {frames} fotogramas";
        }

        private void DoneButton_Click(object sender, RoutedEventArgs e)
        {
            OnDoneClicked?.Invoke();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            OnCancelClicked?.Invoke();
        }

        protected override void OnKeyDown(System.Windows.Input.KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.Key == Key.Enter)
            {
                OnDoneClicked?.Invoke();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                OnCancelClicked?.Invoke();
                e.Handled = true;
            }
        }
    }
}
