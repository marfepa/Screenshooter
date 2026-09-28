# Ámbito: capturador

> **Regla de oro:** Este documento es la verdad técnica de este módulo. Cualquier agente asignado a este ámbito debe leerlo antes de inspeccionar o editar archivos. Al finalizar una tarea, si se descubre una peculiaridad o cambia el terreno, este documento debe actualizarse en la misma sesión.

---

## 1. Estado Actual

- **Objetivo del ámbito:** Módulo central de Screenshooter en macOS responsable de registrar el atajo global de teclado, desplegar la ventana de selección interactiva de área en pantalla, capturar la porción recortada en alta resolución (Retina), transferir la imagen resultante al portapapeles (`NSPasteboard`) y emitir feedback háptico/sonoro.
- **Fase:** Implementado y validado en tests unitarios.
- **Funcionalidades completadas:**
  - [x] Maqueta viva interactiva con todos los estados y auditoría HIG aprobada con mención de excelencia (`mockup/index.html`).
  - [x] Generación del proyecto nativo Xcode con `xcodegen` (`project.yml`).
  - [x] Configuración de la aplicación en segundo plano residente en MenuBar (`LSUIElement = true`).
  - [x] Implementación del registrador de atajo global de teclado (`HotKeyManager` con Carbon APIs nativas `RegisterEventHotKey`).
  - [x] Implementación del gestor de ventana de superposición (`SelectionOverlayWindow` y `SelectionView` en AppKit).
  - [x] Captura de píxeles del área seleccionada con `ScreenCaptureKit` (`SCScreenshotManager.captureImage`) con adaptación a pantallas Retina (`NSScreen.backingScaleFactor`).
  - [x] Copia al portapapeles (`ClipboardService` hacia `NSPasteboard.general` en formatos TIFF y PNG).
  - [x] Feedback al usuario (sonido nativo de obturador `AudioServicesPlaySystemSound(1108)` y HUD de confirmación flotante).
  - [x] Verificación y solicitud de permisos de grabación de pantalla con deep link a Ajustes del Sistema (`PermissionsHelper`).
  - [x] Pruebas unitarias de conversión de coordenadas y escritura en portapapeles (`ScreenshooterTests`).
- **Pendiente / Roadmap inmediato:**
  - [ ] Añadir panel gráfico interactivo para remapear teclas en Ajustes.
  - [ ] Registro en `SMAppService` para inicio automático al encender el Mac.
- **Deuda técnica conocida:**
  - Ninguna.

---

## 2. Terreno de Juego (Ficheros y Límites)

> **Límite operativo:** El agente asignado a este ámbito solo tiene autorización para editar los archivos listados abajo. Si requiere modificar código fuera de su terreno, debe detenerse y pedir autorización al Supervisor.

### Archivos bajo propiedad de este ámbito:
- `project.yml`
- `Screenshooter.xcodeproj`
- `Screenshooter/Sources/App/main.swift`
- `Screenshooter/Sources/App/AppDelegate.swift`
- `Screenshooter/Sources/Capture/CaptureCoordinator.swift`
- `Screenshooter/Sources/Capture/SelectionOverlayWindow.swift`
- `Screenshooter/Sources/Capture/SelectionView.swift`
- `Screenshooter/Sources/Capture/ScreenCaptureEngine.swift`
- `Screenshooter/Sources/HotKey/HotKeyManager.swift`
- `Screenshooter/Sources/Clipboard/ClipboardService.swift`
- `Screenshooter/Sources/UI/StatusBarController.swift`
- `Screenshooter/Sources/UI/HUDNotificationWindow.swift`
- `Screenshooter/Sources/UI/PermissionsHelper.swift`
- `Screenshooter/Resources/Info.plist`
- `ScreenshooterTests/ScreenshooterTests.swift`
- `docs/ambitos/capturador.md`
- `mockup/index.html`

### Dependencias externas permitidas (solo lectura/uso nativo):
- macOS SDK (AppKit, Carbon, ScreenCaptureKit, CoreGraphics, AudioToolbox).
- XcodeGen para regenerar el `.xcodeproj`.

---

## 3. Modelo de Datos y Dominio del Ámbito

- **Entidades principales:**
  - `CaptureSession`: Modelo efímero que almacena el estado de una captura en curso (`id`, `screen`, `startPoint`, `currentRect`, `status`).
  - `CaptureResult`: Encapsula la imagen capturada (`cgImage`, `pixelSize`, `timestamp`, `displayScale`).
  - `HotKeyBinding`: Define la combinación de teclas (`keyCode: UInt32`, `modifiers: UInt32`). Valor por defecto: `⌥⌘S` (Option + Command + S).
  - `PermissionStatus`: Enum de estado de grabación de pantalla (`unknown`, `granted`, `denied`).
- **Máquina de estados del capturador:**
  - `Idle` (esperando atajo o clic en barra de menús)
  - `OverlayActive` (pantalla atenuada, cursor en cruz, esperando inicio de arrastre)
  - `SelectingArea` (usuario arrastrando con botón pulsado, recalculando rectángulo y dimensiones en tiempo real)
  - `ProcessingCapture` (soltado de ratón, cálculo de coordenadas lógicas a píxeles de pantalla, llamada a ScreenCaptureKit)
  - `CopiedToClipboard` (transferencia a `NSPasteboard`, disparo de sonido y HUD flotante, regreso inmediato a `Idle`)
  - `Cancelled` (tecla Escape pulsada o clic sin arrastrar, cierre del overlay sin acción, regreso a `Idle`)
- **Invariantes y reglas de negocio:**
  - Si el usuario pulsa `ESC` en cualquier momento, el overlay se descarta al instante sin escribir en el portapapeles.
  - Si el área seleccionada es menor a 4×4 píxeles (un clic accidental), se cancela la captura para evitar imágenes corruptas o vacías en el portapapeles.
  - Las coordenadas de AppKit (origen en esquina inferior izquierda) deben convertirse correctamente al sistema de coordenadas de CoreGraphics / ScreenCaptureKit (origen en esquina superior izquierda) considerando la altura total del display y la escala Retina (`backingScaleFactor`).
  - La aplicación debe operar sin icono en el Dock (`LSUIElement = true`).

---

## 4. Trampas Encontradas (Gotchas y Lecciones Aprendidas)

> *«Mejorar un agente consiste en mejorar este listado para no volver a tropezar dos veces con la misma piedra.»*

- ⚠️ **Sistemas de coordenadas en macOS:** `NSView` / `NSWindow` miden con origen `(0, 0)` en la esquina inferior izquierda del display primario (`NSScreen.screens.first`). Sin embargo, `ScreenCaptureKit` usa origen `(0, 0)` en la esquina superior izquierda. La conversión requiere: `localY = screenFrame.height - (rect.origin.y - screenFrame.origin.y + rect.height)`.
- ⚠️ **Obsolescencia de CGDisplayCreateImageForRect:** En SDKs modernos (macOS 15+), `CGDisplayCreateImageForRect` está marcada como obsoleta. Es imperativo utilizar `ScreenCaptureKit` (`SCScreenshotManager.captureImage`), requiriendo `deploymentTarget: 14.0` en `project.yml`.
- ⚠️ **Escala Retina (Backing Scale Factor):** Un rectángulo lógico de 200×100 en un monitor Retina equivale a 400×200 píxeles reales. Al pasar la imagen a `NSPasteboard`, debe asignarse `NSImage(cgImage: cgImage, size: logicalSize)` para que al pegarse en aplicaciones mantenga su tamaño visual proporcional sin pixelación.
- ⚠️ **Atajos globales con Carbon vs. CGEventTap:** `RegisterEventHotKey` de Carbon API no requiere permisos de accesibilidad del sistema (Accessibility en Privacidad y Seguridad), lo cual ofrece la mejor experiencia de usuario posible sin fricciones de configuración de teclado.
- ⚠️ **Aislamiento MainActor en Swift 6:** En `main.swift`, la inicialización de `NSApplicationDelegate` (`AppDelegate`) debe envolverse en `MainActor.assumeIsolated { ... }` para satisfacer el chequeo estricto de concurrencia.
- ⚠️ **Generación de Info.plist en Tests de XcodeGen:** Para targets de tipo `bundle.unit-test`, es obligatorio declarar `GENERATE_INFOPLIST_FILE: YES` en sus build settings para que `codesign` ad-hoc no aborte la ejecución de los tests.
- ⚠️ **Subclases de NSWindow e inicializador designado de AppKit:** En AppKit, el inicializador designado de `NSWindow` es `init(contentRect:styleMask:backing:defer:)`. Si se crea una subclase en Swift y se invoca `super.init(..., screen:)` sin sobreescribir explícitamente el designado, el runtime de Swift lanza `Fatal error: Use of unimplemented initializer 'init(contentRect:styleMask:backing:defer:)'`. Toda subclase debe sobreescribir `override init(contentRect:styleMask:backing:defer:)` y usar inicializadores de conveniencia (`convenience init`).
- ⚠️ **Persistencia de permisos TCC y reinicio obligatorio en macOS:** Al activar la autorización de Grabación de Pantalla en Ajustes del Sistema, macOS no actualiza los permisos del proceso en caliente; el proceso debe reiniciarse obligatoriamente para que TCC conceda el acceso. Asimismo, llamar a `CGRequestScreenCaptureAccess()` repetidamente en cada pulsación provoca un bucle molesto del diálogo del sistema; debe solicitarse una sola vez y ofrecer reinicio inmediato. La firma ad-hoc debe fijar `--requirements '=designated => identifier "com.marfepa.Screenshooter"'` para evitar que TCC invalide los permisos con cada variación de `cdhash`.
- ⚠️ **ScreenCaptureKit sourceRect y recorte exacto con cropping(to:):** En `SCStreamConfiguration`, configurar `sourceRect` con `scalesToFit = false` e indicar dimensiones menores al display causa que el compositor de ScreenCaptureKit recorte respecto al origen `(0,0)` del display, omitiendo selecciones en otras áreas de la pantalla. La solución más robusta y sin artefactos consiste en capturar el display nativo con ScreenCaptureKit y aplicar `fullImage.cropping(to: cropRect)` con coordenadas de píxeles calculadas a partir de la densidad Retina (`backingScaleFactor`).
