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
  - [x] Icono de aplicación nativo estilo macOS Golden Gate mate (squircle oficial, retícula de visor de captura y marcas de encuadre, sin brillos ni reflejos, catálogo `Assets.xcassets/AppIcon.appiconset` y `AppIcon.icns`).
  - [x] Compilación Release y despliegue local en `/Applications/Screenshooter.app`.
- **Pendiente / Roadmap inmediato:**
  - [ ] Añadir panel gráfico interactivo para remapear teclas en Ajustes.
  - [ ] Registro en `SMAppService` para inicio automático al encender el Mac.
- **Deuda técnica conocida:**
  - `PermissionsHelper.promptPermissionDialogIfNeeded()` aún usa `alert.runModal()` (pre-overlay, riesgo bajo pero inconsistente con el patrón no-bloqueante).
  - `activeHUD` en `CaptureCoordinator` retiene la instancia cerrada hasta la próxima captura; añadir callback `onDismiss` para limpiar.
  - Falta soporte de `Cmd + .` como alternativa a ESC para cancelar selección (convención HIG).

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
- `Screenshooter/Resources/Assets.xcassets`
- `Screenshooter/Resources/AppIcon.icns`
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
- ⚠️ **NSAlert.runModal() en apps LSUIElement:** `runModal()` bloquea el hilo principal hasta que el usuario cierra la alerta. Si la app opera como `LSUIElement` (sin icono en Dock), la alerta puede quedar invisible detrás de otras ventanas. Solución segura: activar la app con `NSApp.activate(ignoringOtherApps: true)`, elevar `alert.window.level = .floating` y usar `runModal()` solo cuando los overlays ya están cerrados. **No usar `beginSheetModal(for:)` con una ventana borderless de 1×1** porque esa ventana no puede ser key, provocando un crash de `_NSGlassEffectWindow`.
- ⚠️ **Nivel de ventana .screenSaver bloquea el sistema:** El nivel `.screenSaver` (1000) se sitúa por encima de alertas del sistema, Force Quit (⌥⌘Esc) y prácticamente toda la interfaz de macOS. Si un overlay a este nivel no se cierra, el usuario queda atrapado. Usar `NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)` (102) es suficiente para cubrir ventanas normales, Dock y barra de menú sin bloquear mecanismos de emergencia.
- ⚠️ **Flags de estado sin defer en Tasks:** Si un flag como `isCapturing` se resetea solo al final de un `Task`, cualquier excepción intermedia deja el flag en `true` permanentemente, bloqueando futuras operaciones. Siempre usar `defer { flag = false }` como primera sentencia dentro del `Task`.
- ⚠️ **HUDNotificationWindow y ARC:** Las ventanas creadas como variables locales sin retención explícita pueden ser liberadas por ARC antes de que finalice su animación o timer de auto-cierre. Mantener una referencia fuerte en el coordinador hasta que la ventana complete su ciclo de vida.
- ⚠️ **super.keyDown() produce NSBeep:** Propagar `super.keyDown(with:)` en vistas overlay provoca el sonido de error del sistema en cada tecla no gestionada. Consumir el evento silenciosamente para evitar molestias acústicas.
- ⚠️ **`isReleasedWhenClosed` + ARC = double-free (EXC_BAD_ACCESS):** Por defecto, `NSWindow.isReleasedWhenClosed` es `true`. Cuando se llama a `close()`, AppKit envía un `release` extra a nivel Objective-C. Si ARC también libera la misma referencia (al salir de ámbito, `removeAll()`, etc.), se produce un **double-free** → `EXC_BAD_ACCESS` en `objc_release`. **Toda subclase de NSWindow gestionada por ARC debe declarar `self.isReleasedWhenClosed = false`** en su inicializador.
- ⚠️ **`beginSheetModal(for:)` requiere ventana que soporte key:** `NSAlert.beginSheetModal(for:)` necesita que la ventana anfitrión pueda convertirse en key window (`canBecomeKey == true`). Las ventanas con `styleMask: [.borderless]` devuelven `false` por defecto, lo que provoca que la alerta cree una `_NSGlassEffectWindow` interna que tampoco puede ser key → crash. Usar ventanas con `.titled` o sobreescribir `canBecomeKey`.
- ⚠️ **Catálogo de iconos con XcodeGen y caché de LaunchServices en macOS:** Para que un bundle macOS compile el icono sin depender de bundles de activos externos, es imprescindible declarar `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` en `project.yml` e incluir `CFBundleIconFile` y `CFBundleIconName` en `Info.plist`. Asimismo, al instalar manualmente en `/Applications`, macOS mantiene en caché los iconos de `LaunchServices`; forzar el registro con `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/<App>.app` asegura el refresco instantáneo del icono en Finder y Dock.
- ⚠️ **Arrastre desde el Tendedero (`.move` y Papelera):** Finder completa el `.move` de un arrastre de forma asíncrona, por lo que al recibir `.move` en `endedAt` el archivo aún puede existir; hay que comprobar su existencia tras ~0.6 s antes de sacar el item de la tira. La Papelera del Dock solo informa `.delete` (no borra nada): borrar (mover a la Papelera) es responsabilidad de la app origen. El pasteboard writer debe ser `item.url as NSURL`; escribir el path con `setString(_, forType: .fileURL)` no es una URL válida y Finder rechaza el archivo.
- ⚠️ **Descartar capturas = Papelera, nunca `removeItem`:** Evicción por `maxItems`, `clear()` y la ✕ usan `TendederoManager.trasher` (por defecto `FileManager.trashItem`), inyectable en tests para no ensuciar la Papelera real.
- ⚠️ **Monitor local de NSEvent en app LSUIElement:** `addLocalMonitorForEvents(.mouseMoved)` solo recibe eventos de las ventanas propias, nunca movimientos sobre otras apps ni la barra de menús. Para detectar el hover usar un timer que lea `NSEvent.mouseLocation` (o un monitor global). Los clics sí se vigilan con monitor global + local.
- ⚠️ **Timer en `.common`:** los `Timer` deben añadirse a `RunLoop.main` en modo `.common`; con `scheduledTimer` (modo default) se congelan durante el tracking de menús (justo cuando se hace clic en la barra de menús).
- ⚠️ **FullScreen usa API privada:** `CGSMainConnectionID`/`CGSCopyManagedDisplaySpaces` (vía `@_silgen_name`) no son públicas; la app no es apta para la Mac App Store mientras se use. Si desaparecen, `FullScreen.isActive` debe degradarse a `false`.
- ⚠️ **Panel de pantalla completa y clics:** el panel del Tendedero ocupa todo el ancho, por eso `ignoresMouseEvents = true` salvo sobre una tarjeta (`cardHitRects`, con 4 pt de margen) y nunca se cambia durante un arrastre/pulsación (`TendederoCardView.isBusy`). Usa `visibleFrame` para quedar bajo la barra de menús, no `frame`.
