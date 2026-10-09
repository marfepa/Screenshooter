import Foundation

/// Punto único para elegir el bundle y la configuración regional con los que se resuelven los textos.
/// En la app son siempre `Bundle.main` y `Locale.current`; los tests los sustituyen para comprobar
/// cada idioma (`en.lproj` / `es.lproj`) sin cambiar el idioma del sistema.
///
/// Todo texto visible usa `String(localized: …, bundle: L10n.bundle, locale: L10n.locale, comment: …)`
/// con claves en inglés natural (idioma de desarrollo) y catálogo `Localizable.xcstrings`.
enum L10n {
    static var bundle: Bundle = .main
    static var locale: Locale = .autoupdatingCurrent
}
