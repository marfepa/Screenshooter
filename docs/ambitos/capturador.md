# Ámbito: capturador

> **Regla de oro:** Este documento es la verdad técnica de este módulo. Cualquier agente asignado a este ámbito debe leerlo antes de inspeccionar o editar archivos. Al finalizar una tarea, si se descubre una peculiaridad o cambia el terreno, este documento debe actualizarse en la misma sesión.

---

## 1. Estado Actual

- **Objetivo del ámbito:** Módulo central de Screenshooter en macOS responsable de registrar el atajo global de teclado, desplegar la ventana de selección interactiva de área en pantalla, capturar la porción recortada en alta resolución (Retina), transferir la imagen resultante al portapapeles (`NSPasteboard`) y emitir feedback háptico/sonoro.
- **Fase:** Planificación inicial y diseño (Ticket propuesto).
- **Funcionalidades completadas:**
  - [x] Maqueta viva interactiva con todos los estados y auditoría HIG (`mockup/index.html`).
- **Pendiente / Roadmap inmediato:**
  - [ ] Generación del proyecto nativo Xcode con `xcodegen` (`project.yml`).
  - [ ] Configuración de la aplicación en segundo plano residente en MenuBar (`LSUIElement = true`).
  - [ ] Implementación del registrador de atajo global de teclado (`HotKeyManager` con Carbon APIs nativas `RegisterEventHotKey`).
  - [ ] Implementación del gestor de ventana de superposición (`SelectionOverlayWindow` y `SelectionView` en AppKit).
  - [ ] Captura de píxeles del área seleccionada con `ScreenCaptureKit` / `CGWindowListCreateImage` adaptado a pantallas Retina (`NSScreen.backingScaleFactor`).
  - [ ] Copia al portapapeles (`ClipboardService` hacia `NSPasteboard.general`).
  - [ ] Feedback al usuario (sonido de obturador del sistema `NSSound` y HUD de confirmación).
  - [ ] Verificación y solicitud de permisos de grabación de pantalla (`CGPreflightScreenCaptureAccess` y `CGRequestScreenCaptureAccess`).
- **Deuda técnica conocida:**
  - Ninguna (proyecto creado desde cero).

---

## 2. Terreno de Juego (Ficheros y Límites)

> **Límite operativo:** El agente asignado a este ámbito solo tiene autorización para editar los archivos listados abajo. Si requiere modificar código fuera de su terreno, debe detenerse y pedir autorización al Supervisor.

### Archivos bajo propiedad de este ámbito:
- `project.yml` (Especificación XcodeGen)
- `Screenshooter/Sources/App/AppDelegate.swift`
- `Screenshooter/Sources/App/ScreenshooterApp.swift`
- `Screenshooter/Sources/Capture/CaptureCoordinator.swift`
- `Screenshooter/Sources/Capture/SelectionOverlayWindow.swift`
- `Screenshooter/Sources/Capture/SelectionView.swift`
- `Screenshooter/Sources/Capture/ScreenCaptureEngine.swift`
- `Screenshooter/Sources/HotKey/HotKeyManager.swift`
- `Screenshooter/Sources/Clipboard/ClipboardService.swift`
- `Screenshooter/Sources/UI/StatusBarController.swift`
- `Screenshooter/Sources/UI/PermissionsView.swift`
- `Screenshooter/Sources/UI/HUDNotificationWindow.swift`
- `Screenshooter/Resources/Info.plist`
- `ScreenshooterTests/...`
- `docs/ambitos/capturador.md`
- `mockup/index.html`

### Dependencias externas permitidas (solo lectura/uso nativo):
- macOS SDK (AppKit, SwiftUI, Carbon, ScreenCaptureKit, CoreGraphics, AVFoundation).
- XcodeGen para regenerar el `.xcodeproj`.

---

## 3. Modelo de Datos y Dominio del Ámbito

- **Entidades principales:**
  - `CaptureSession`: Modelo efímero que almacena el estado de una captura en curso (`id`, `screen`, `startPoint`, `currentRect`, `status`).
  - `CaptureResult`: Encapsula la imagen capturada (`cgImage`, `pixelSize`, `timestamp`, `displayScale`).
  - `HotKeyBinding`: Define la combinación de teclas (`keyCode: UInt32`, `modifiers: UInt32`). Por defecto: `⌥⌘S` (Option + Command + S).
  - `PermissionStatus`: Enum de estado de grabación de pantalla (`unknown`, `granted`, `denied`).
- **Máquina de estados del capturador:**
  - `Idle` (esperando atajo o clic en barra de menús)
  - `OverlayActive` (pantalla atenuada, cursor en cruz, esperando inicio de arrastre)
  - `SelectingArea` (usuario arrastrando con botón pulsado, recalculando rectángulo y dimensiones en tiempo real)
  - `ProcessingCapture` (soltado de ratón, cálculo de coordenadas lógicas a píxeles de pantalla, llamada al motor de captura)
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

- ⚠️ **Sistemas de coordenadas en macOS:** `NSView` / `NSWindow` miden con origen `(0, 0)` en la esquina inferior izquierda del display primario (`NSScreen.screens.first`). Sin embargo, `CGDisplayCreateImageForRect` y `ScreenCaptureKit` usan origen `(0, 0)` en la esquina superior izquierda. La conversión requiere: `cgY = screenHeight - (nsY + nsHeight)`.
- ⚠️ **Escala Retina (Backing Scale Factor):** Un rectángulo lógico de 200×100 en un monitor Retina equivale a 400×200 píxeles reales. Al pasar la imagen a `NSPasteboard`, debe empaquetarse preservando la escala o representarse en TIFF/PNG de forma que al pegarse en otras aplicaciones conserve la nitidez 2x sin verse al doble de tamaño.
- ⚠️ **Permisos de grabación en macOS Sonoma / Sequoia:** Desde macOS 14+, Apple solicita y recuerda el permiso por bundle identifier. Si la app se ejecuta desde la línea de comandos sin Info.plist firmado o bundle empaquetado, macOS puede denegar silenciosamente la captura devolviendo una imagen con el fondo de pantalla en vez del contenido de las ventanas. El paquete `.app` generado por Xcode debe poseer su Info.plist configurado correctamente.
- ⚠️ **Atajos globales con Carbon vs. CGEventTap:** `RegisterEventHotKey` de Carbon API no requiere permisos de accesibilidad del sistema (Accessibility en Privacidad y Seguridad), lo cual ofrece la mejor experiencia de usuario posible sin fricciones de configuración de teclado.
- ⚠️ **Múltiples pantallas:** Si el usuario tiene más de un monitor conectado, la ventana overlay debe extenderse a través de todos los monitores o crear una ventana overlay transparente por cada `NSScreen.screens`.
