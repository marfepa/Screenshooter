using System;
using System.Windows;
using System.Windows.Forms;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.Capture.Windows
{
    public partial class NavigationPillWindow : Window
    {
        public event Action? OnExitClicked;

        public NavigationPillWindow()
        {
            InitializeComponent();
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            this.MakeNonActivating();

            // Centrar horizontalmente en el monitor principal, arriba
            var primary = Screen.PrimaryScreen?.Bounds ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
            Left = primary.Left + (primary.Width - ActualWidth) / 2;
            Top = primary.Top + 24;
        }

        private void ExitButton_Click(object sender, RoutedEventArgs e)
        {
            OnExitClicked?.Invoke();
        }
    }
}
