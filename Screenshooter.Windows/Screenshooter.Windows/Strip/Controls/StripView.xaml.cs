using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using Screenshooter.Windows.Core.Models;

namespace Screenshooter.Windows.Strip.Controls
{
    public partial class StripView : UserControl
    {
        private readonly List<StripCardControl> _cards = new();

        public event Action<StripItem>? OnItemDismissed;

        public StripView()
        {
            InitializeComponent();
        }

        public void SetItems(IEnumerable<StripItem> items)
        {
            CardsCanvas.Children.Clear();
            _cards.Clear();

            foreach (var item in items)
            {
                var card = new StripCardControl(item);
                card.OnDismissRequested += Card_OnDismissRequested;
                _cards.Add(card);
                CardsCanvas.Children.Add(card);
            }

            RelayoutCards(animated: false);
        }

        public void AddItem(StripItem item)
        {
            var card = new StripCardControl(item);
            card.OnDismissRequested += Card_OnDismissRequested;

            // Las capturas más recientes van al principio (a la izquierda)
            _cards.Insert(0, card);
            CardsCanvas.Children.Add(card);

            RelayoutCards(animated: true);
        }

        private void Card_OnDismissRequested(StripCardControl card)
        {
            _cards.Remove(card);
            CardsCanvas.Children.Remove(card);
            OnItemDismissed?.Invoke(card.Item);
            RelayoutCards(animated: true);
        }

        public void RelayoutCards(bool animated = true)
        {
            double w = ActualWidth;
            if (w <= 0) return;

            var frames = StripMotion.CardFrames(_cards.Count, w);

            for (int i = 0; i < _cards.Count && i < frames.Count; i++)
            {
                var card = _cards[i];
                var targetRect = frames[i];

                if (!animated)
                {
                    Canvas.SetLeft(card, targetRect.X);
                    Canvas.SetTop(card, targetRect.Y);
                }
                else
                {
                    double curLeft = Canvas.GetLeft(card);
                    double curTop = Canvas.GetTop(card);

                    if (double.IsNaN(curLeft) || double.IsNaN(curTop))
                    {
                        // Nueva tarjeta entrando: aparece desde arriba
                        Canvas.SetLeft(card, targetRect.X);
                        Canvas.SetTop(card, targetRect.Y - 40);

                        var enterAnim = new DoubleAnimation(targetRect.Y, TimeSpan.FromMilliseconds(400))
                        {
                            EasingFunction = new ElasticEase { Oscillations = 1, Springiness = 4 }
                        };
                        card.BeginAnimation(Canvas.TopProperty, enterAnim);
                    }
                    else
                    {
                        // Reposicionamiento suave
                        var leftAnim = new DoubleAnimation(targetRect.X, TimeSpan.FromMilliseconds(350))
                        {
                            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
                        };
                        var topAnim = new DoubleAnimation(targetRect.Y, TimeSpan.FromMilliseconds(350))
                        {
                            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
                        };
                        card.BeginAnimation(Canvas.LeftProperty, leftAnim);
                        card.BeginAnimation(Canvas.TopProperty, topAnim);
                    }
                }
            }
        }

        private void RootGrid_SizeChanged(object sender, SizeChangedEventArgs e)
        {
            Rope.InvalidateVisual();
            RelayoutCards(animated: false);
        }
    }
}
