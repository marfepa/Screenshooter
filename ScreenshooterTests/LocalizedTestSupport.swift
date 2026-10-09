import XCTest
@testable import Screenshooter

/// Fija el bundle/idioma con el que la app resuelve sus textos durante un test.
enum LocalizedTestSupport {
    static func lprojBundle(_ code: String) -> Bundle? {
        let host = Bundle(for: StripManager.self)
        guard let path = host.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    static func use(_ code: String) {
        L10n.bundle = lprojBundle(code) ?? .main
        L10n.locale = Locale(identifier: code == "es" ? "es_ES" : "en_GB")
    }

    static func reset() {
        L10n.bundle = .main
        L10n.locale = .current
    }
}
