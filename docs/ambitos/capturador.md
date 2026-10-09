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
- `mockup/tira.html` (especificación visual y de interacción de la tira)
- `Screenshooter/Sources/Tendedero/*` (tira: `StripMotion.swift` y `StripScroll.swift` lógica pura (física, rango visible, capacidad), `TendederoCardView`, `TendederoView`, `TendederoPanel`, `TendederoManager`, `CaptureFlight`, `RevealState`)

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
- ⚠️ **Capturas nativas y archivo oculto:** `screencapture` escribe primero un archivo oculto (`.Captura de pantalla….png`) y luego lo renombra. `InboxManager` debe filtrar nombres que empiecen por "." y esperar a que el tamaño del archivo sea estable (>0, dos lecturas iguales) antes de colgarlo.
- ⚠️ **Inbox y caché propia en carpetas distintas:** la carpeta vigilada por el Modo Inbox (`TendederoManager.inboxDirectory`) debe ser distinta de la caché de capturas propias (`screenshotsDirectory`), o cada captura se cuelga dos veces. `hang()` además ignora URLs ya presentes en la tira.
- ⚠️ **Vidrio en panel transparente (`blendingMode`):** `NSVisualEffectView` con `.withinWindow` solo mezcla el contenido de la propia ventana; en un panel `isOpaque = false` y fondo `.clear` eso es nada, así que no se ve desenfoque. Usar `.behindWindow` (+ `material = .popover`, `state = .active` para que no se apague cuando el panel no es key). Las esquinas se redondean con `maskImage` (NSImage con `capInsets`), no con `cornerRadius` (no recorta el desenfoque). Con Reducir transparencia se oculta el efecto y se pinta `windowBackgroundColor` (`GlassSurface`). Sin verificar a ojo en esta sesión (no había sesión gráfica).
- ⚠️ **`canBecomeKey` en `.nonactivatingPanel`:** el panel de la tira devuelve `canBecomeKey = true` solo mientras hay una petición de teclado (⌃⌥T, `keyboardRequested`); así recibe teclas sin activar la app y un clic en una tarjeta nunca le roba el foco a la app de debajo. `resignKey()` cierra la sesión de teclado; con foco de teclado `busy` impide recoger la tira. Al recoger no se llama a `NSApp.hide` ni se reactiva nada: el foco nunca salió de la app anterior. `acceptsFirstResponder` de la tarjeta depende de `window.canBecomeKey`.
- ⚠️ **Transform y `anchorPoint` en vistas con capa:** AppKit gestiona `position`/`bounds` de la capa de una `NSView`; cambiar el `anchorPoint` de esa capa descoloca la vista. El ancla "arriba-centro" se consigue horneándola en la matriz (`StripMotion.cardTransform(tilt:scale:pivotOffset:)`: traslada -d, rota+escala, traslada +d). OJO: el `anchorPoint` de la capa de una `NSView` en macOS NO es el centro (suele ser (0,0)) y AppKit puede reasignarlo/resetear `transform` en layout; d = pivote − anchorPoint·tamaño se lee de la capa real en cada aplicación (`TendederoCardView.pivotOffset(of:at:)`) y `layout()` reaplica el transform de reposo. Hay un test (`testCardHoverAndTiltKeepTopCenterFixedInParent`) que comprueba que el punto superior-centro no se mueve con el anchor real. Inclinación y escala van en UNA sola `CATransform3D` (si se animaban por separado, el hover reseteaba el giro y saltaba). El balanceo (`swingView`) y la inclinación/escala (`cardBody`) están en capas distintas para no pisarse.
- ⚠️ **Animar con modelo = destino:** `CALayer.animateValue` (en `StripMotion.swift`) fija primero el valor final en el modelo (con acciones implícitas desactivadas) y luego añade la animación explícita desde la presentación actual; si no, la capa vuelve al valor anterior al terminar. Las recolocaciones usan animaciones aditivas de `position` (delta → 0) y la caída de llegada `transform.translation.y` aditiva, para no tocar el frame real que gestiona AppKit.
- ⚠️ **Despliegue sin mover la ventana:** la ventana del panel es fija; lo que se desliza es `slideHost` (translation.y con `CASpringAnimation`). La propia ventana recorta lo que sube por encima, que queda bajo la barra de menús. `alphaValue` del panel ya no se anima (siempre 1). Hay que usar `layer.animation(forKey: "slide")` para saber si arrancar desde la presentación o desde fuera de pantalla.
- ⚠️ **Hover desde el timer, no desde tracking areas:** con `ignoresMouseEvents = true` salvo sobre una tarjeta, `mouseExited` no llega fiable. El hover lo calcula el tick del panel (`TendederoView.updateHover`). Las tarjetas son hit-testables solo en su rectángulo (`hitRect`); `cardHitRects` se calcula con él, no con el frame de la ranura (150×146, incluye la cápsula de hora).
- ⚠️ **Hit test del área de 32 pt:** un subview solo recibe clics dentro de su frame, así que ✕/lápiz (`CircleGlassButton`) miden 32×32 y dibujan el círculo de 24; `TendederoCardView.hitTest` los devuelve explícitamente y si no devuelve la propia tarjeta (el `NSImageView` no debe quedarse el clic).
- ⚠️ **Gestos:** `mouseUp` no copia si hubo arrastre (`suppressNextMouseUp`: el `mouseUp` puede llegar tras `endedAt`) ni pulsación larga. `clickCount == 2` ya usa `NSEvent.doubleClickInterval`; el primer clic copia y el segundo abre Vista Previa. Control+clic se redirige a `rightMouseDown`. El menú contextual marca `menuOpen` en `menuWillOpen/menuDidClose` (cuenta como `busy`).
- ⚠️ **Archivo no encontrado:** `perform(_:)` es el único punto de entrada de acciones y vuelve a comprobar `fileExists` al actuar; si falta, copiar/descartar llaman a `removeFromStrip` (sin Papelera, `trasher` no se invoca) y el resto no hace nada. Se re-evalúa también al desplegar la tira (`refreshMissingStates`).
- ⚠️ **Teclado:** una sola parada de Tab (`isRovingStop`/`canBecomeKeyView`), flechas/Inicio/Fin mueven el foco, ⌘O/⌘⌫/⌘C llegan por `performKeyEquivalent` (solo actúa el first responder; todas las tarjetas lo reciben) y Supr/Intro/Espacio/M/⇧F10 por `keyDown`. Esc recoge y las teclas no gestionadas se consumen sin pitido. `drawFocusRingMask` usa el rectángulo de la tarjeta (sin la escala de hover).
- ⚠️ **Reducir movimiento:** `MotionStyle.current(reduceMotion:)` decide todo (sin muelles, escalas ni rotaciones animadas; fundidos de 0,2 s). Sin vuelo de captura: `hang()` no marca `isFlying` y la tarjeta aparece con fundido. La inclinación estática del item se conserva.
- ⚠️ **Orden en `hang()`:** primero `peek()` (despliega la ventana) y después `reloadPanel()`: las animaciones de llegada solo corren con la ventana visible (`window.isVisible`). `trash(itemID:)` marca la tarjeta con `markForFall` antes de recargar y retrasa `slideUp` la duración de la caída cuando la tira queda vacía.
- ⚠️ **`xcodegen` añade un grupo vacío `TEMP_… /* .claude */`** al `project.pbxproj`; no está referenciado: borrar el bloque tras cada `xcodegen generate`. En el sandbox, `xcodegen` y `xcodebuild` necesitan ejecutarse sin sandbox.
- ⚠️ **`busy` por instancia:** `TendederoCardView.isBusy` agrega `Set<ObjectIdentifier>` de tarjetas pulsando / con menú abierto; `resetInteractionState()` (en `playFall`, `playDisappear` y `viewDidMoveToWindow` con window nil) invalida el timer y limpia, para que una tarjeta que desaparece a mitad de pulsación no deje la tira sin poder recogerse.
- ⚠️ **Sesión de teclado pegada:** un clic fuera del panel (monitor global) con `keyboardRequested` termina la sesión y recoge; `reveal` resigna un panel que siga key sin petición. ⌃⌥T con la tira revelada por ratón abre sesión de teclado; con sesión ya abierta, recoge.
- ⚠️ **Paso de clics durante el slide:** `cardHitRects` suma la traslación mostrada (`presentation()`), y el hover se desactiva mientras `isSliding`.
- ⚠️ **Hora:** se formatea con `timeStyle = .short` y la locale del sistema (12/24 h); los tests fijan `es_ES`.
- ⚠️ **Tests de capas fuera de ventana:** `layer.superlayer` es nil hasta que la vista se muestra; para comprobar geometría usa la matemática `pos + T·(p − anchor·size)` con el anchor real.
- ⚠️ **Marcación (`com.apple.MarkupUI.Markup`) y cómo devuelve el resultado:** no se pudo verificar a ojo cuál variante usa cada versión de macOS, así que `MarkupService.resolveEdited` cubre las tres: `NSImage` en memoria (se escribe PNG sobre el original), `URL` distinta (copia editada en otra ruta: `replaceAtomically` = copia a temporal en el mismo directorio + `replaceItemAt`, conserva ruta y nombre) y la misma URL (edición in situ, nada que copiar). La edición in situ puede escribirse DESPUÉS de `didShareItems`, por eso `TendederoManager` vigila el archivo (`MarkupFileWatcher`, `DispatchSource` con `.write/.extend/.rename/.delete/.attrib`) hasta 10 s tras `onFinished`, con debounce de 0,15 s y tamaño estable. La escritura atómica SUSTITUYE el inode: el descriptor abierto apunta al archivo viejo, así que en `.rename/.delete` hay que reabrirlo sobre la misma ruta. Diagnóstico: `log stream --predicate 'subsystem == "com.marfepa.Screenshooter" AND category == "Markup"' --level debug`.
- ⚠️ **`TendederoItem.reloadFromDisk()`:** usa `CGImageSourceCreateWithURL` con `kCGImageSourceShouldCache: false` y actualiza `pixelSize`/`logicalSize` (Marcación puede recortar) conservando la relación píxeles/puntos del item. El sonido del portapapeles suena solo una vez por sesión de Marcación.
- ⚠️ **Tira desplazable = offset, no frames:** la posición de cada tarjeta es `slotX(i) − offset` (`StripScroll.Metrics`); la cuerda no se mueve y la `y` de la tarjeta sale de `StripMotion.ropeY` en su `x` de pantalla en CADA fotograma (`TendederoView.placeCard`). Si todo cabe, `start` centra las tarjetas igual que `StripMotion.cardFrames` (hay test). Las recolocaciones por altas/bajas usan la animación aditiva `reposition(delta:)` calculada en coordenadas de pantalla antes/después, así que no se animan al desplazar.
- ⚠️ **Virtualización:** solo hay vista para las tarjetas visibles ±1 (`StripScroll.mountedRange`) más la que va a recibir el foco de teclado (`focusPendingID`/`isKeyboardFocused`); las demás se reciclan (`pool`, `resetForReuse`/`reconfigure(with:)`, sin animar el cambio de inclinación). `cardViews` ya NO contiene todas las capturas: usa `indexByID`/`currentItems`. Forzar el montaje de la tarjeta enfocada solo mientras tenga el foco, o siempre habrá una vista lejana montada.
- ⚠️ **Bucle de animación:** `NSView.displayLink(target:selector:)` (macOS 14) solo se crea con ventana y se invalida en reposo (`step` devuelve `false`); retiene a la vista hasta entonces. `dt` sale de `link.timestamp` limitado a 50 ms. `StripScroller.tick` es puro y se prueba con `advanceForTesting`. La tira no se recoge mientras `isScrollBusy` (scroller o bucle activos); el panel tampoco cambia `ignoresMouseEvents`.
- ⚠️ **Rueda y trackpad:** `scrollingDeltaX/Y` ya incorporan el desplazamiento natural; no invertir signos a mano (solo `offset -= delta`, contenido a la derecha = offset menor). Con fases del sistema (`phase`/`momentumPhase` no vacías y deltas precisos) se sigue el delta sin inercia propia y, al acabar el gesto, solo hay muelle de vuelta; sin fases (rueda de ratón, líneas × `wheelLineHeight`) hay inercia propia tras 0,1 s de silencio. Ignorar `phase == .mayBegin`. La histéresis de eje (`AxisLock`) se libera al salir de `wheel/drag`. El valor de `wheelLineHeight` (12) y el ajuste fino de la sensibilidad NO están probados con hardware.
- ⚠️ **Hit-testing de la franja de la cuerda:** `RopeDragView` va DEBAJO de `cardStack` (que es `PassthroughView`: devuelve `nil` si no hay tarjeta bajo el punto) para que donde se solapan mande la tarjeta; su `hitTest` solo acepta ±10 pt alrededor de la curva y solo si la tira se desplaza. El panel suma tarjetas + contadores + franja en `containsInteractivePoint`; la rueda solo llega en esas zonas porque fuera `ignoresMouseEvents = true`. Cursor mano abierta/cerrada por `NSTrackingArea(.cursorUpdate, .activeAlways)` (la app es LSUIElement y no está activa): sin verificar a ojo.
- ⚠️ **Inclinación por velocidad:** va en `swingView` (pivote = pinza, `swingPivot` leído del anchor real), no en `cardBody`, y se reaplica en `layout()` por si AppKit resetea la capa. Se salta en desplazamientos programáticos (`StripScroller.isProgrammatic`, modo `.anim`) y con Reducir movimiento. Las animaciones de llegada (`playSwing`) comparten capa: mientras corren mandan sobre el valor del modelo.
- ⚠️ **Captura nueva con la tira desplazada (I6):** si el usuario interactúa (puntero en la zona, arrastre/rueda o foco en una tarjeta) NO se vuelve al inicio: se desplaza el origen (`StripScroller.shift`) para que las tarjetas no se muevan, el contador izquierdo suma +1 con `bump()` y se anuncia. Si no, se compensa igual y se anima a 0 (350 ms) EN PARALELO al vuelo (la maqueta lo hacía en secuencia; el destino del vuelo debía existir). El destino del vuelo (`screenFrame(for:)`) se calcula con la geometría del offset objetivo; si queda fuera por la izquierda vuela al contador «+N».
- ⚠️ **VoiceOver y tarjetas sin vista:** `cardStack.accessibilityChildren` lleva TODAS las capturas (vista real o `StripProxyElement`); se reconstruye solo en reposo (`accessibilityDirty`). `NSAccessibilityScrollToVisibleAction` solo existe desde macOS 26 (deployment 14): en su lugar, `setAccessibilityFocused(true)` (tarjeta o proxy) llama a `ensureVisible`, y al reposar se publica `.focusedUIElementChanged` sobre la tarjeta real. Pendiente de probar con VoiceOver.
- ⚠️ **Capacidad (`stripCapacity`):** `TendederoManager.capacity` (0 = sin límite, por defecto 32, opciones 8·16·32·0 en `StripCapacity`). `maxItems` queda como alias. `defaults` es inyectable: los tests de capacidad usan una suite propia porque el host de tests ES la app y escribiría en los ajustes reales. Al bajarla (`setCapacity`) las sobrantes van a la Papelera con caída y se anuncia «Se quitaron N capturas más antiguas». El menú «Capturas en la tira» identifica la opción por `NSMenuItem.tag`.
- ⚠️ **Máscara de bordes:** `CAGradientLayer` como `mask` de la capa de `cardStack` (40 pt, 16 con Aumentar contraste; alfa 0,43 justo en el borde, como el fundido por tarjeta de la maqueta), solo cuando la tira se desplaza; su `frame` hay que actualizarlo a mano en `layout()` (una máscara no es sublayer).
