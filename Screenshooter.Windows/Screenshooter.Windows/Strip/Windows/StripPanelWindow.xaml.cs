using System;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Interop;

namespace Screenshooter.Windows.Strip.Windows
{
    public partial class StripPanelWindow : Window
    {
        public bool IsRevealed { get; private set; }
        public bool IsPinned { get; set; }

        private DispatcherTimer? _edgeMonitorTimer;
        private bool _isAnimating;

        public StripPanelWindow()
        {
            InitializeComponent();
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            this.MakeNonActivating();
            PositionOnScreen();

            _edgeMonitorTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(120)
            };
            _edgeMonitorTimer.Tick += EdgeMonitorTimer_Tick;
            _edgeMonitorTimer.Start();
        }

        public void PositionOnScreen()
        {
            // Posicionar en el borde superior del monitor principal o el que contiene el cursor
            Win32.GetCursorPos(out var pt);
            var screen = Screen.FromPoint(new System.Drawing.Point(pt.X, pt.Y)) ?? Screen.PrimaryScreen;
            if (screen != null)
            {
                Left = screen.Bounds.Left;
                Top = screen.Bounds.Top;
                Width = screen.Bounds.Width;
            }
        }

        private void EdgeMonitorTimer_Tick(object? sender, EventArgs e)
        {
            if (_isAnimating) return;

            Win32.GetCursorPos(out var pt);

            // Coordenadas relativas a este panel
            bool isInsideX = pt.X >= Left && pt.X <= (Left + Width);
            bool isAtTopEdge = pt.Y >= Top && pt.Y <= (Top + 3);
            bool isInsidePanel = pt.Y >= Top && pt.Y <= (Top + Height);

            if (!IsRevealed)
            {
                // El ratón ha tocado el borde superior de la pantalla: revelar tira
                if (isInsideX && isAtTopEdge)
                {
                    Reveal(pinned: false);
                }
            }
            else
            {
                // La tira está desplegada: si el ratón se aleja hacia abajo y no está fijada, recoger
                if (!IsPinned && (!isInsideX || pt.Y > (Top + Height + 20)))
                {
                    SlideUp();
                }
            }
        }

        public void Toggle()
        {
            if (IsRevealed)
            {
                SlideUp();
            }
            else
            {
                PositionOnScreen();
                Reveal(pinned: true);
            }
        }

        public void Reveal(bool pinned = false)
        {
            if (IsRevealed) return;
            IsRevealed = true;
            IsPinned = pinned;
            _isAnimating = true;

            var slideAnim = new DoubleAnimation(0.0, TimeSpan.FromMilliseconds(380))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            slideAnim.Completed += (s, e) => _isAnimating = false;
            PanelTransform.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, slideAnim);
        }

        public void SlideUp()
        {
            if (!IsRevealed) return;
            IsRevealed = false;
            IsPinned = false;
            _isAnimating = true;

            var slideAnim = new DoubleAnimation(-180.0, TimeSpan.FromMilliseconds(220))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
            };
            slideAnim.Completed += (s, e) => _isAnimating = false;
            PanelTransform.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, slideAnim);
        }

        public void AddItem(StripItem item)
        {
            StripViewControl.AddItem(item);
            // Al capturar una nueva foto, desplegar la tira brevemente para mostrarla colgada
            PositionOnScreen();
            Reveal(pinned: false);
        }
    }
}
