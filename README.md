<p align="center">
  <img src="docs/images/icono.png" width="128" height="128" alt="Icono de Screenshooter">
</p>

# Screenshooter

App de capturas de pantalla para macOS y Windows: seleccionas un área, se copia al portapapeles y queda colgada en una Tira de tarjetas desde la que puedes reutilizarla.

> [!NOTE]
> ¿Usas Windows? Consulta [Screenshooter para Windows](Screenshooter.Windows/README.md) para la versión nativa de Windows 10/11 en .NET 8.

![La Tira: capturas colgadas de una cuerda bajo la barra de menús](docs/images/tira.png)

## Requisitos

### macOS
- macOS 14 (Sonoma) o posterior.
- Mac con Apple Silicon o Intel (binario universal).

### Windows
- Windows 10 (versión 1903 o posterior) o Windows 11.
- Arquitectura x64 o ARM64.
- No requiere instalar ningún runtime previo (la versión compilada en Releases es autocontenida).

## Instalación

### macOS

1. Descarga el `.dmg` de la última versión en la [página de Releases](https://github.com/marfepa/Screenshooter/releases/latest).
2. Ábrelo y arrastra `Screenshooter.app` a la carpeta Aplicaciones.

#### Primera apertura en macOS: aviso de seguridad

Screenshooter no está notarizada por Apple, así que macOS mostrará un aviso la primera vez. Hay dos formas de abrirla:

**Método 1: desde Ajustes del Sistema**

1. Intenta abrir la app (macOS la bloqueará).
2. Ve a Ajustes del Sistema → Privacidad y seguridad.
3. Junto al aviso sobre Screenshooter, pulsa «Abrir igualmente».

**Método 2: desde Terminal**

```bash
xattr -dr com.apple.quarantine /Applications/Screenshooter.app
```

### Windows

1. Descarga el archivo `Screenshooter-Windows-vX.Y.Z-x64.zip` de la última versión en la [página de Releases](https://github.com/marfepa/Screenshooter/releases/latest).
2. Descomprime el archivo `.zip` en la carpeta que prefieras (por ejemplo, en `C:\Program Files\Screenshooter` o en una carpeta de tu usuario).
3. Ejecuta `Screenshooter.exe`.

#### Primera apertura en Windows: aviso de SmartScreen

Al ser un ejecutable independiente de código abierto sin certificado de firma de pago, Windows Defender SmartScreen puede mostrar un aviso la primera vez (*"Windows protegió su PC"*):

1. Haz clic en **«Más información»**.
2. Haz clic en el botón **«Ejecutar de todas formas»**.

> [!TIP]
> **Bandeja del sistema e inicio automático:**  
> Screenshooter se ejecuta como servicio residente en segundo plano y verás su icono en la **bandeja del sistema** (System Tray, junto al reloj de Windows). Puedes hacer clic derecho en el icono para ver sus opciones y activar **«Iniciar al arrancar el sistema»**.

### Verificar la descarga (opcional)

Descarga también el archivo `.sha256` correspondiente de la release y comprueba su integridad:

- **macOS:**
  ```bash
  shasum -a 256 -c Screenshooter-X.Y.Z.dmg.sha256
  ```
- **Windows (PowerShell):**
  ```powershell
  Get-FileHash .\Screenshooter-Windows-vX.Y.Z-x64.zip -Algorithm SHA256
  ```

## Permisos

- **macOS:** Requiere permiso de Grabación de pantalla (Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla). La app te guía hasta ese panel. Tras concederlo, reinicia la app.
- **Windows:** No requiere permisos especiales ni elevación de privilegios de administrador.

## Uso

Screenshooter vive en la barra de menús (macOS) o en la bandeja del sistema (Windows).

- **Captura continua de área:**
  - **macOS:** `⌥⌘S`
  - **Windows:** `Alt + Shift + S`
  - Selecciona un área: se copia de inmediato al portapapeles y se cuelga en la Tira. Puedes seguir capturando áreas consecutivas hasta pulsar `ESC`.
  - Mueve la rueda del ratón o toca el trackpad con dos dedos para apartar temporalmente la capa de captura y desplazarte o navegar por la ventana inferior.
  - Vuelve a pulsar el atajo para cambiar a modo navegación libre (aparece la píldora flotante con botón «Salir»); vuelve a pulsarlo para seguir capturando.
- **Captura larga con costura (scroll):** Mantén `⇧` (`Shift`) al soltar la selección o selecciona «Captura larga…» en el menú; haz scroll hacia abajo y Screenshooter combinará los fotogramas en una imagen continua. Pulsa «Listo» o `Enter` para finalizar y `ESC` para cancelar.
- **Mostrar / ocultar la Tira:**
  - **macOS:** `⌃⌥T` (o lleva el puntero al borde superior de la pantalla).
  - **Windows:** `Ctrl + Alt + T` (o lleva el puntero al borde superior de la pantalla).

Gestos sobre cada captura de la Tira:

- Clic: copiar al portapapeles (muestra un aviso flotante HUD).
- Doble clic: abrir en Vista Previa (macOS) o en el visor de fotos predeterminado (Windows).
- Clic derecho o mantener pulsado: menú de acciones (copiar, editar, mostrar en explorador/Finder, eliminar).
- Arrastrar y soltar: llevar la tarjeta directamente a Slack, Discord, Teams, Figma, navegador o carpetas.
- Botón ✕: descartar la captura de la Tira.

## Compilar desde el código

### macOS

```bash
brew install xcodegen
xcodegen generate
open Screenshooter.xcodeproj
```

O genera directamente el `.dmg` universal en `build/`:

```bash
scripts/release.sh
```

### Windows

Requiere [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd Screenshooter.Windows
dotnet run --project Screenshooter.Windows/Screenshooter.Windows.csproj
```

O compila y empaqueta el binario portable único y `.zip`:

```powershell
cd Screenshooter.Windows
.\build.ps1
```

## Publicar una versión

1. Sube `CFBundleShortVersionString` en `Screenshooter/Resources/Info.plist`.
2. Crea y sube el tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

3. GitHub Actions compila, empaqueta y publica la release con el `.dmg` y su checksum. Un tag con sufijo (por ejemplo `vX.Y.Z-rc1`) se publica como pre-release.

## Licencia

MIT, ver [LICENSE](LICENSE). El diseño de la Tira y parte de su código se inspiran en [Tendedero](https://github.com/alejandrobujan/tendedero) de Alejandro Buján (MIT); ver [NOTICE](NOTICE).
