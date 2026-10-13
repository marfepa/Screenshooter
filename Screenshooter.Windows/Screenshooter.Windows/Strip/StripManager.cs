using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Services;
using Screenshooter.Windows.Strip.Windows;

namespace Screenshooter.Windows.Strip
{
    public sealed class StripManager
    {
        public static StripManager Instance { get; } = new();

        public event Action? OnItemsChanged;

        private readonly List<StripItem> _items = new();
        public IReadOnlyList<StripItem> Items => _items.AsReadOnly();

        public int Capacity { get; set; } = 16; // Por defecto: 16 capturas

        private StripPanelWindow? _panelWindow;

        private StripManager() { }

        public void Initialize()
        {
            _panelWindow = new StripPanelWindow();
            _panelWindow.StripViewControl.OnItemDismissed += HandleItemDismissed;
            _panelWindow.Show();

            HotKeyManager.Instance.OnToggleStripHotKey += Toggle;
            InboxManager.Instance.OnScreenshotImported += Add;
        }

        public void Add(StripItem item)
        {
            _items.Insert(0, item);

            // Respetar límite de capacidad
            if (Capacity > 0 && _items.Count > Capacity)
            {
                var overflow = _items.Skip(Capacity).ToList();
                foreach (var old in overflow)
                {
                    _items.Remove(old);
                }
            }

            _panelWindow?.AddItem(item);
            OnItemsChanged?.Invoke();
        }

        public void Toggle()
        {
            _panelWindow?.Toggle();
        }

        public void Clear()
        {
            _items.Clear();
            _panelWindow?.StripViewControl.SetItems(_items);
            OnItemsChanged?.Invoke();
        }

        public void SetCapacity(int capacity)
        {
            Capacity = capacity;
            if (Capacity > 0 && _items.Count > Capacity)
            {
                var overflow = _items.Skip(Capacity).ToList();
                foreach (var old in overflow)
                {
                    _items.Remove(old);
                }
                _panelWindow?.StripViewControl.SetItems(_items);
                OnItemsChanged?.Invoke();
            }
        }

        private void HandleItemDismissed(StripItem item)
        {
            _items.Remove(item);
            OnItemsChanged?.Invoke();
        }
    }
}
