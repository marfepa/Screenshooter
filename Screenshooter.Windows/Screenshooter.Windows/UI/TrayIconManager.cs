using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Screenshooter.Windows.Capture;
using Screenshooter.Windows.Core.Models;
using Screenshooter.Windows.Core.Storage;
using Screenshooter.Windows.Services;
using Screenshooter.Windows.Strip;

namespace Screenshooter.Windows.UI
{
    public sealed class TrayIconManager : IDisposable
    {
        public static TrayIconManager Instance { get; } = new();

        private NotifyIcon? _notifyIcon;
        private ContextMenuStrip? _contextMenu;

        private TrayIconManager() { }

        public void Initialize()
        {
            _contextMenu = new ContextMenuStrip();
            _notifyIcon = new NotifyIcon
            {
                Text = "Screenshooter (Alt+Shift+S para capturar)",
                Visible = true,
                ContextMenuStrip = _contextMenu
            };

            // Cargar icono desde archivo o recurso
            string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "tray.ico");
            if (File.Exists(iconPath))
            {
                _notifyIcon.Icon = new Icon(iconPath);
            }
            else
            {
                // Fallback a icono genérico de aplicación
                _notifyIcon.Icon = SystemIcons.Application;
            }

            _notifyIcon.DoubleClick += (s, e) => CaptureCoordinator.Instance.ToggleCapture();

            BuildMenu();

            CaptureCoordinator.Instance.OnStateChanged += BuildMenu;
        }

        public void BuildMenu()
        {
            if (_contextMenu == null) return;
            _contextMenu.Items.Clear();

            // 1. Acciones principales de captura
            var captureItem = new ToolStripMenuItem("Capturar área...", null, (s, e) => CaptureCoordinator.Instance.ToggleCapture())
            {
                ShortcutKeyDisplayString = "Alt+Shift+S",
                Font = new Font(_contextMenu.Font, System.Drawing.FontStyle.Bold)
            };
            _contextMenu.Items.Add(captureItem);

            var longCaptureItem = new ToolStripMenuItem("Captura larga...", null, (s, e) => CaptureCoordinator.Instance.StartScrollCaptureSelection());
            _contextMenu.Items.Add(longCaptureItem);

            if (CaptureCoordinator.Instance.IsActive)
            {
                var exitCaptureItem = new ToolStripMenuItem("Salir del modo captura", null, (s, e) => CaptureCoordinator.Instance.CancelCapture());
                _contextMenu.Items.Add(exitCaptureItem);
            }

            _contextMenu.Items.Add(new ToolStripSeparator());

            // 2. Control de la Tira
            var toggleStripItem = new ToolStripMenuItem("Mostrar / Ocultar Tira", null, (s, e) => StripManager.Instance.Toggle())
            {
                ShortcutKeyDisplayString = "Ctrl+Alt+T"
            };
            _contextMenu.Items.Add(toggleStripItem);

            var clearStripItem = new ToolStripMenuItem("Limpiar Tira", null, (s, e) => StripManager.Instance.Clear());
            _contextMenu.Items.Add(clearStripItem);

            // Modo Inbox
            var inboxItem = new ToolStripMenuItem("Modo Inbox (capturas nativas de Windows van a la Tira)", null, (s, e) =>
            {
                InboxManager.Instance.IsEnabled = !InboxManager.Instance.IsEnabled;
                BuildMenu();
            })
            {
                Checked = InboxManager.Instance.IsEnabled
            };
            _contextMenu.Items.Add(inboxItem);

            // Capacidad de la tira
            var capacityMenu = new ToolStripMenuItem("Capacidad de la Tira");
            foreach (var opt in StripCapacity.Options)
            {
                int val = opt;
                var optItem = new ToolStripMenuItem(StripCapacity.TitleFor(val), null, (s, e) =>
                {
                    StripManager.Instance.SetCapacity(val);
                    BuildMenu();
                })
                {
                    Checked = (StripManager.Instance.Capacity == val)
                };
                capacityMenu.DropDownItems.Add(optItem);
            }
            _contextMenu.Items.Add(capacityMenu);

            _contextMenu.Items.Add(new ToolStripSeparator());

            // 3. Ajustes y Utilidades
            var openFolderItem = new ToolStripMenuItem("Abrir carpeta de capturas", null, (s, e) => StripStorage.OpenFolderInExplorer());
            _contextMenu.Items.Add(openFolderItem);

            var launchAtLoginItem = new ToolStripMenuItem("Abrir al iniciar sesión", null, (s, e) =>
            {
                LaunchAtLoginManager.Toggle();
                BuildMenu();
            })
            {
                Checked = LaunchAtLoginManager.IsEnabled
            };
            _contextMenu.Items.Add(launchAtLoginItem);

            _contextMenu.Items.Add(new ToolStripSeparator());

            // 4. Salir
            var quitItem = new ToolStripMenuItem("Salir de Screenshooter", null, (s, e) =>
            {
                System.Windows.Application.Current.Shutdown();
            });
            _contextMenu.Items.Add(quitItem);
        }

        public void Dispose()
        {
            if (_notifyIcon != null)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
                _notifyIcon = null;
            }
            _contextMenu?.Dispose();
            _contextMenu = null;
        }
    }
}
