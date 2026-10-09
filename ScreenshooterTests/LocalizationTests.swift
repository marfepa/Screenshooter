import XCTest
import AppKit
@testable import Screenshooter

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        LocalizedTestSupport.reset()
        super.tearDown()
    }

    // MARK: Catálogo

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func loadCatalog(_ name: String) throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent("Screenshooter/Resources/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isTranslated(_ unit: Any?) -> Bool {
        guard let u = (unit as? [String: Any])?["stringUnit"] as? [String: Any] else { return false }
        return u["state"] as? String == "translated" && !((u["value"] as? String) ?? "").isEmpty
    }

    /// Una localización es válida si es una cadena traducida o un conjunto de variaciones `plural` con `one` y `other`.
    private func localizationIsComplete(_ loc: Any?) -> Bool {
        if isTranslated(loc) { return true }
        guard let plural = ((loc as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return false }
        return isTranslated(plural["one"]) && isTranslated(plural["other"])
    }

    func testCatalogsAreEnglishBasedAndFullyTranslated() throws {
        for name in ["Localizable", "InfoPlist"] {
            let catalog = try loadCatalog(name)
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en", name)
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty, name)
            for (key, value) in strings {
                let locs = (value as? [String: Any])?["localizations"] as? [String: Any]
                for lang in ["en", "es"] {
                    XCTAssertTrue(localizationIsComplete(locs?[lang]), "\(name): «\(key)» sin traducción \(lang) en estado translated")
                }
            }
        }
    }

    func testCatalogPlaceholdersMatchBetweenLanguages() throws {
        let strings = try XCTUnwrap(try loadCatalog("Localizable")["strings"] as? [String: Any])
        func values(_ loc: Any?) -> [String] {
            if let u = ((loc as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { return [u] }
            let plural = (((loc as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any]) ?? [:]
            return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        func placeholders(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|@)")
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
                String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression)
            }.sorted()
        }
        for (key, value) in strings {
            let locs = (value as? [String: Any])?["localizations"] as? [String: Any]
            let expected = placeholders(key)
            for lang in ["en", "es"] {
                for v in values(locs?[lang]) {
                    XCTAssertEqual(placeholders(v), expected, "«\(key)» [\(lang)]: marcadores distintos en «\(v)»")
                }
            }
        }
    }

    func testPluralStringsHaveVariantsInBothLanguages() throws {
        let strings = try XCTUnwrap(try loadCatalog("Localizable")["strings"] as? [String: Any])
        let pluralKeys = ["%lld captures",
                          "Removed %lld oldest captures",
                          "Show %lld more captures to the left",
                          "Show %lld more captures to the right",
                          "New capture. Shelf at start, %lld captures"]
        for key in pluralKeys {
            let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            for lang in ["en", "es"] {
                let plural = (((locs?[lang] as? [String: Any])?["variations"] as? [String: Any])?["plural"]) as? [String: Any]
                XCTAssertNotNil(plural?["one"], "«\(key)» [\(lang)] sin variante one")
                XCTAssertNotNil(plural?["other"], "«\(key)» [\(lang)] sin variante other")
            }
        }
    }

    // MARK: Código fuente

    private func swiftSources() -> [URL] {
        let dir = Self.repoRoot.appendingPathComponent("Screenshooter/Sources")
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (en?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Quita el comentario de línea (`//…`) respetando las comillas.
    private func code(of line: String) -> String {
        var inString = false
        var prev: Character = " "
        var out = ""
        for ch in line {
            if ch == "\"" && prev != "\\" { inString.toggle() }
            if !inString && ch == "/" && prev == "/" { out.removeLast(); break }
            out.append(ch)
            prev = ch
        }
        return out
    }

    func testNoSpanishLiteralsLeftInSources() throws {
        let spanish = CharacterSet(charactersIn: "áéíóúñÁÉÍÓÚÑ¿¡")
        var offenders: [String] = []
        for file in swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            var inBlockComment = false
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                var line = raw
                if inBlockComment {
                    if let r = line.range(of: "*/") { line = String(line[r.upperBound...]); inBlockComment = false } else { continue }
                }
                if line.contains("/*") && !line.contains("*/") { inBlockComment = true; line = String(line[..<line.range(of: "/*")!.lowerBound]) }
                let c = code(of: line)
                // Los registros de depuración (NSLog / log) no son texto de interfaz.
                if c.contains("NSLog(") || c.contains("log.") || c.contains("Logger") { continue }
                if c.unicodeScalars.contains(where: { spanish.contains($0) }) {
                    offenders.append("\(file.lastPathComponent):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Literales en español sin localizar:\n" + offenders.joined(separator: "\n"))
    }

    func testEveryLocalizedKeyUsedInSourcesExistsInCatalog() throws {
        let keys = Set((try XCTUnwrap(try loadCatalog("Localizable")["strings"] as? [String: Any])).keys)
        let re = try NSRegularExpression(pattern: "String\\(localized:\\s*(?:\"(?!\"\")((?:[^\"\\\\]|\\\\.)*)\"|\"\"\"\\n\\s*([^\\n]*))")
        var checked = 0
        for file in swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let isMultiline = m.range(at: 1).location == NSNotFound
                let group = Range(m.range(at: isMultiline ? 2 : 1), in: text)!
                let literal = String(text[group]).replacingOccurrences(of: "\\'", with: "'")
                let prefix = literal.components(separatedBy: "\\(").first ?? literal
                checked += 1
                if literal.contains("\\(") || isMultiline {
                    XCTAssertTrue(keys.contains { $0.hasPrefix(prefix) }, "\(file.lastPathComponent): clave con interpolación sin entrada en el catálogo: \(literal)")
                } else {
                    XCTAssertTrue(keys.contains(literal), "\(file.lastPathComponent): clave sin entrada en el catálogo: \(literal)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 40, "Debería haber decenas de usos de String(localized:)")
    }

    func testOldProjectNameAppearsOnlyInNotice() throws {
        let root = Self.repoRoot
        let oldName = "tende" + "dero"  // partido para que el propio test no contenga el nombre
        for sub in ["Screenshooter", "ScreenshooterTests", "docs", "mockup", "project.yml"] {
            let url = root.appendingPathComponent(sub)
            let files: [URL]
            if url.pathExtension == "yml" { files = [url] } else {
                files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { ["swift", "md", "xcstrings", "plist", "yml", "html"].contains($0.pathExtension) }
            }
            for f in files where f.lastPathComponent != "LocalizationTests.swift" {
                let text = try String(contentsOf: f, encoding: .utf8)
                XCTAssertFalse(text.lowercased().contains(oldName), "\(f.lastPathComponent) menciona el nombre antiguo")
            }
        }
    }

    // MARK: Resolución por idioma

    func testBothLanguageBundlesExistInTheApp() {
        XCTAssertNotNil(LocalizedTestSupport.lprojBundle("en"), "Falta en.lproj en el .app")
        XCTAssertNotNil(LocalizedTestSupport.lprojBundle("es"), "Falta es.lproj en el .app")
    }

    func testInfoPlistUsageDescriptionIsLocalized() throws {
        let key = "NSScreenCaptureUsageDescription"
        let en = try XCTUnwrap(LocalizedTestSupport.lprojBundle("en")).localizedString(forKey: key, value: nil, table: "InfoPlist")
        let es = try XCTUnwrap(LocalizedTestSupport.lprojBundle("es")).localizedString(forKey: key, value: nil, table: "InfoPlist")
        XCTAssertTrue(en.hasPrefix("Screenshooter needs access"), en)
        XCTAssertTrue(es.hasPrefix("Screenshooter necesita acceso"), es)
    }

    func testStripTextsInSpanishAndEnglishWithPlurals() {
        LocalizedTestSupport.use("es")
        XCTAssertEqual(StripCapacity.title(for: 0), "Sin límite")
        XCTAssertEqual(StripCapacity.removalAnnouncement(1), "Se quitó 1 captura más antigua")
        XCTAssertEqual(StripCapacity.removalAnnouncement(3), "Se quitaron 3 capturas más antiguas")
        XCTAssertEqual(StripScroll.countsDescription(1), "1 captura")
        XCTAssertEqual(StripScroll.countsDescription(32), "32 capturas")
        XCTAssertEqual(StripScroll.counterLabel(count: 1, side: .left), "Mostrar 1 captura más a la izquierda")
        XCTAssertEqual(StripScroll.counterLabel(count: 12, side: .right), "Mostrar 12 capturas más a la derecha")
        XCTAssertEqual(StripScroll.restAnnouncement(hiddenLeft: 4, hiddenRight: 23, total: 32), "Mostrando de la 5 a la 9 de 32")
        XCTAssertEqual(StripScroll.newCaptureAtStartNote(total: 1), "Nueva captura. Tira al inicio, 1 captura")
        XCTAssertEqual(StripScroll.newCaptureAtStartNote(total: 5), "Nueva captura. Tira al inicio, 5 capturas")
        XCTAssertEqual(StripScroll.newCaptureLeftNote, "Nueva captura añadida a la izquierda")
        XCTAssertEqual(StripMotion.positionText(index: 1, count: 8), "2 de 8")

        LocalizedTestSupport.use("en")
        XCTAssertEqual(StripCapacity.title(for: 0), "Unlimited")
        XCTAssertEqual(StripCapacity.removalAnnouncement(1), "Removed 1 oldest capture")
        XCTAssertEqual(StripCapacity.removalAnnouncement(3), "Removed 3 oldest captures")
        XCTAssertEqual(StripScroll.countsDescription(1), "1 capture")
        XCTAssertEqual(StripScroll.countsDescription(32), "32 captures")
        XCTAssertEqual(StripScroll.counterLabel(count: 1, side: .left), "Show 1 more capture to the left")
        XCTAssertEqual(StripScroll.counterLabel(count: 12, side: .right), "Show 12 more captures to the right")
        XCTAssertEqual(StripScroll.restAnnouncement(hiddenLeft: 4, hiddenRight: 23, total: 32), "Showing 5 to 9 of 32")
        XCTAssertEqual(StripScroll.newCaptureAtStartNote(total: 1), "New capture. Shelf at start, 1 capture")
        XCTAssertEqual(StripScroll.newCaptureAtStartNote(total: 5), "New capture. Shelf at start, 5 captures")
        XCTAssertEqual(StripScroll.newCaptureLeftNote, "New capture added on the left")
        XCTAssertEqual(StripMotion.positionText(index: 1, count: 8), "2 of 8")
    }

    private func makeTestImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return context.makeImage()
    }

    @MainActor
    func testCardTextsFollowLanguage() throws {
        let cg = try XCTUnwrap(makeTestImage())
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 14, minute: 32)))
        let item = StripItem(url: URL(fileURLWithPath: "/tmp/x.png"), cgImage: cg,
                             pixelSize: CGSize(width: 1440, height: 900), createdAt: date)

        LocalizedTestSupport.use("es")
        var loc = L10n.locale
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: false, locale: loc), "Captura, 14:32, 1440 por 900")
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: true, locale: loc), "Captura no encontrada, 14:32")
        XCTAssertEqual(StripMotion.metaText(for: item, locale: loc), "14:32 · 1440×900")

        LocalizedTestSupport.use("en")
        loc = L10n.locale
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: false, locale: loc), "Capture, 14:32, 1440 by 900")
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: true, locale: loc), "Capture not found, 14:32")
        XCTAssertEqual(StripMotion.metaText(for: item, locale: loc), "14:32 · 1440×900")
    }

    @MainActor
    func testEdgeCounterAndEmptyStateFollowLanguage() {
        LocalizedTestSupport.use("en")
        let button = EdgeCountButton(side: .right)
        button.setCount(12, animated: false)
        XCTAssertEqual(button.accessibilityLabel(), "Show 12 more captures to the right")
        XCTAssertEqual(button.toolTip, "Show 12 more captures to the right")

        LocalizedTestSupport.use("es")
        let button2 = EdgeCountButton(side: .left)
        button2.setCount(1, animated: false)
        XCTAssertEqual(button2.accessibilityLabel(), "Mostrar 1 captura más a la izquierda")
    }

    func testCaptureErrorsFollowLanguage() {
        LocalizedTestSupport.use("en")
        XCTAssertEqual(ScreenCaptureError.permissionDenied.errorDescription, "Screen recording permission has not been granted.")
        XCTAssertEqual(ScreenCaptureError.captureFailed("x").errorDescription, "Failed to capture the screen: x")
        LocalizedTestSupport.use("es")
        XCTAssertEqual(ScreenCaptureError.permissionDenied.errorDescription, "Permiso de grabación de pantalla no concedido.")
        XCTAssertEqual(ScreenCaptureError.captureFailed("x").errorDescription, "Error al capturar la pantalla: x")
    }
}
