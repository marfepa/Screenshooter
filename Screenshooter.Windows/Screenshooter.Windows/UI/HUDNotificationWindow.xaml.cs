using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Media.Animation;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.UI
{
    public partial class HUDNotificationWindow : Window
    {
        public HUDNotificationWindow(string message)
        {
            InitializeComponent();
            MessageText.Text = message;
        }

        private async void Window_Loaded(object sender, RoutedEventArgs e)
        {
            this.MakeNonActivating();

            // Centrar en pantalla principal
            var screen = Screen.PrimaryScreen?.Bounds ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
            Left = screen.Left + (screen.Width - ActualWidth) / 2;
            Top = screen.Top + (screen.Height - ActualHeight) / 2;

            // Fade in
            var fadeIn = new DoubleAnimation(0.0, 1.0, TimeSpan.FromMilliseconds(150));
            BeginAnimation(OpacityProperty, fadeIn);

            await Task.Delay(1100);

            // Fade out y cerrar
            var fadeOut = new DoubleAnimation(1.0, 0.0, TimeSpan.FromMilliseconds(200));
            fadeOut.Completed += (s, ev) => Close();
            BeginAnimation(OpacityProperty, fadeOut);
        }

        public static void ShowMessage(string message)
        {
            System.Windows.Application.Current.Dispatcher.Invoke(() =>
            {
                var hud = new HUDNotificationWindow(message);
                hud.Show();
            });
        }
    }
}
