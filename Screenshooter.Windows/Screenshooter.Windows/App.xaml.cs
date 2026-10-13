using System;
using System.Threading;
using System.Windows;
using Screenshooter.Windows.Capture;
using Screenshooter.Windows.Services;
using Screenshooter.Windows.Strip;
using Screenshooter.Windows.UI;

namespace Screenshooter.Windows
{
    public partial class App : System.Windows.Application
    {
        private const string MutexName = "Screenshooter_SingleInstance_Mutex_9F218B";
        private Mutex? _instanceMutex;

        protected override void OnStartup(StartupEventArgs e)
        {
            // Garantizar una única instancia ejecutándose en segundo plano
            _instanceMutex = new Mutex(true, MutexName, out bool isNewInstance);
            if (!isNewInstance)
            {
                // Ya hay una instancia corriendo: avisar o salir
                Shutdown();
                return;
            }

            base.OnStartup(e);

            try
            {
                // Inicializar servicios centrales
                HotKeyManager.Instance.Initialize();
                StripManager.Instance.Initialize();
                CaptureCoordinator.Instance.Initialize();
                TrayIconManager.Instance.Initialize();
            }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show(
                    $"Error al iniciar Screenshooter: {ex.Message}",
                    "Screenshooter",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                Shutdown();
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            TrayIconManager.Instance.Dispose();
            HotKeyManager.Instance.Dispose();
            InboxManager.Instance.Dispose();

            if (_instanceMutex != null)
            {
                _instanceMutex.ReleaseMutex();
                _instanceMutex.Dispose();
                _instanceMutex = null;
            }

            base.OnExit(e);
        }
    }
}
