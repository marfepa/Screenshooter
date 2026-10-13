# Screenshooter para Windows

Versión nativa de **Screenshooter** para Windows (10 y 11) construida con C# y .NET 8 (WPF + Win32).

Mantiene la misma filosofía, experiencia visual y gestos que la versión de macOS: captura continua de área, panel superior deslizante con fotos colgadas de una cuerda (*La Tira*), y captura larga con costura vertical de scroll.

---

## Características

- **La Tira (The Shelf):**
  - Panel superior flotante con cuerda y tarjetas colgadas con pinzas.
  - Se despliega automáticamente al llevar el cursor al borde superior de la pantalla (`Y <= 2px`), con el atajo global o al tomar una nueva captura.
  - Se retrae suavemente al alejar el ratón.
  - Clic en tarjeta: Copia al portapapeles con aviso visual flotante (HUD).
  - Doble clic: Abre en el visor de fotos predeterminado de Windows.
  - Clic derecho: Menú contextual (Copiar, Abrir, Abrir con Paint, Mostrar en Explorador de archivos, Mover a la papelera).
  - Arrastrar y soltar (Drag & Drop): Arrastra la tarjeta directamente a Slack, Discord, Microsoft Teams, Telegram, Figma o una carpeta de Windows.
  - Botón ✕: Descarta la tarjeta con animación física de caída y giro.

- **Captura Continua (`Alt+Shift+S`):**
  - Overlay de selección multimonitor transparente sin bordes.
  - Modo continuo: tras seleccionar y soltar, la imagen se copia al portapapeles y se cuelga en la Tira, manteniéndose listo para seguir seleccionando áreas hasta pulsar `ESC`.
  - Mover la rueda del ratón aparta temporalmente el overlay para hacer scroll en la ventana inferior.
  - Vuelve a pulsar `Alt+Shift+S` para activar el modo **Navegando** (píldora flotante con botón salir).

- **Captura Larga con Costura (Scroll Capture):**
  - Mantén `Shift` (`⇧`) al soltar la selección o pulsa *Captura larga...* en el menú de la bandeja.
  - Haz scroll hacia abajo mientras el motor analiza las bandas y cose el contenido nuevo en tiempo real.
  - Pulsa *Listo* (o `Enter`) para finalizar la imagen combinada o *Cancelar* (`ESC`).

- **Modo Inbox:**
  - Detecta automáticamente capturas nativas de Windows (`Win+PrtScn` o Recortes) en `%USERPROFILE%\Pictures\Screenshots` y las cuelga de inmediato en la Tira.

- **Bandeja del sistema (System Tray):**
  - Icono residente junto al reloj con menú contextual idéntico al de macOS.
  - Opción de inicio automático al abrir sesión en Windows.

---

## Atajos de teclado

| Atajo | Acción |
| :--- | :--- |
| `Alt+Shift+S` | Iniciar captura continua / Alternar modo Navegando |
| `Ctrl+Alt+T` | Mostrar / Ocultar la Tira fija |
| `Shift` al soltar | Iniciar Captura Larga con scroll |
| `Enter` | Finalizar captura larga |
| `ESC` | Cancelar selección o cerrar Tira |

---

## Requisitos

- Windows 10 (versión 1903 o posterior) o Windows 11.
- Arquitectura x64 o ARM64.
- Para el ejecutable autocontenido no se requiere instalar nada previo. Si se usa el binario dependiente del framework, se requiere [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0).

---

## Compilar desde código fuente

Requiere [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) en Windows.

### Ejecutar en desarrollo:
```powershell
cd Screenshooter.Windows
dotnet run --project Screenshooter.Windows/Screenshooter.Windows.csproj
```

### Generar binario portable `.exe` único y `.zip`:
```powershell
.\build.ps1
```
El ejecutable optimizado y comprimido se generará en la carpeta `build/`.
