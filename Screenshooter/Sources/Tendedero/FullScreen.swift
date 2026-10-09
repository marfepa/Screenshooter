import AppKit

// AVISO: API PRIVADA. CGSMainConnectionID y CGSCopyManagedDisplaySpaces no estan
// documentadas por Apple; el window server conoce el tipo de Space que muestra cada
// pantalla (tipo 4 = app a pantalla completa). No requiere permisos, pero NO es apta
// para la Mac App Store. Si dejara de existir, el enlace fallaria al compilar/arrancar.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

enum FullScreen {
    private static let fullScreenSpaceType = 4

    /// `true` si la pantalla muestra ahora una app a pantalla completa (video, presentacion).
    static func isActive(on screen: NSScreen) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
              !displays.isEmpty else { return false }

        // Con "Las pantallas tienen Spaces distintos" desactivado hay una unica entrada para todas.
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            let uuid = uuidString(for: screen)
            entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        let current = entry?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == fullScreenSpaceType
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
