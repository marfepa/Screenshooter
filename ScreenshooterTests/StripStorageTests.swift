import XCTest
@testable import Screenshooter

final class StripStorageTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    
    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("strip-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }
    
    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    
    func testPathsUseShelfAndLegacyScreenshots() {
        XCTAssertEqual(StripStorage.cacheDirectory(base: base).lastPathComponent, "Shelf")
        XCTAssertEqual(StripStorage.inboxDirectory(base: base).path, StripStorage.cacheDirectory(base: base).path + "/Inbox")
        XCTAssertEqual(StripStorage.legacyCacheDirectory(base: base).lastPathComponent, "Screenshots")
    }
    
    func testNothingToMigrateIsNoOp() {
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 0)
        XCTAssertFalse(fm.fileExists(atPath: StripStorage.cacheDirectory(base: base).path))
    }
    
    func testMovesWholeFolderWhenOnlyLegacyExists() throws {
        let old = StripStorage.legacyCacheDirectory(base: base)
        try write("a", to: old.appendingPathComponent("a.png"))
        try write("b", to: old.appendingPathComponent("Inbox/b.png"))
        
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 2)
        
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(read(StripStorage.cacheDirectory(base: base).appendingPathComponent("a.png")), "a")
        XCTAssertEqual(read(StripStorage.inboxDirectory(base: base).appendingPathComponent("b.png")), "b")
    }
    
    func testMergesWithoutOverwritingWhenBothExist() throws {
        let old = StripStorage.legacyCacheDirectory(base: base)
        let new = StripStorage.cacheDirectory(base: base)
        try write("old", to: old.appendingPathComponent("same.png"))
        try write("old-only", to: old.appendingPathComponent("old.png"))
        try write("old-inbox", to: old.appendingPathComponent("Inbox/x.png"))
        try write("new", to: new.appendingPathComponent("same.png"))
        try write("new-inbox", to: new.appendingPathComponent("Inbox/x.png"))
        
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 3)
        
        XCTAssertEqual(read(new.appendingPathComponent("same.png")), "new", "No se sobrescribe lo nuevo")
        XCTAssertEqual(read(new.appendingPathComponent("same 2.png")), "old", "La colisión conserva el antiguo con nombre único")
        XCTAssertEqual(read(new.appendingPathComponent("old.png")), "old-only")
        XCTAssertEqual(read(new.appendingPathComponent("Inbox/x.png")), "new-inbox")
        XCTAssertEqual(read(new.appendingPathComponent("Inbox/x 2.png")), "old-inbox")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "La carpeta antigua vacía se elimina")
    }
    
    func testMigrationIsIdempotent() throws {
        let old = StripStorage.legacyCacheDirectory(base: base)
        try write("a", to: old.appendingPathComponent("a.png"))
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 1)
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 0)
        XCTAssertEqual(read(StripStorage.cacheDirectory(base: base).appendingPathComponent("a.png")), "a")
    }
    
    func testUniqueURLSkipsTakenNames() throws {
        let dir = base.appendingPathComponent("u", isDirectory: true)
        try write("1", to: dir.appendingPathComponent("f.png"))
        try write("2", to: dir.appendingPathComponent("f 2.png"))
        XCTAssertEqual(StripStorage.uniqueURL(for: dir.appendingPathComponent("f.png")).lastPathComponent, "f 3.png")
    }
    
    func testIsOwnFolderRecognisesLegacyAndNewPaths() {
        let real = StripStorage.defaultBase
        for url in [StripStorage.cacheDirectory(base: real), StripStorage.inboxDirectory(base: real),
                    StripStorage.legacyCacheDirectory(base: real), StripStorage.legacyInboxDirectory(base: real)] {
            XCTAssertTrue(InboxManager.isOwnFolder(path: url.path), url.path)
        }
        XCTAssertFalse(InboxManager.isOwnFolder(path: NSHomeDirectory() + "/Desktop"))
    }
    
    func testMergeDeletesDSStoreAndSkipsOtherHiddenFiles() throws {
        let old = StripStorage.legacyCacheDirectory(base: base)
        let new = StripStorage.cacheDirectory(base: base)
        try write("ds", to: old.appendingPathComponent(".DS_Store"))
        try write("ds", to: old.appendingPathComponent("Inbox/.DS_Store"))
        try write("a", to: old.appendingPathComponent("a.png"))
        try write("n", to: new.appendingPathComponent("n.png"))
        try write("n", to: new.appendingPathComponent("Inbox/n.png"))  // fuerza la fusión recursiva de Inbox
        
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 1)
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("Inbox/.DS_Store").path))
        
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent(".DS_Store").path), ".DS_Store no se copia")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "La carpeta antigua queda vacía y se elimina")
        
        // Otros ocultos no se migran y se conservan en origen.
        let old2 = StripStorage.legacyCacheDirectory(base: base)
        try write("tmp", to: old2.appendingPathComponent(".hidden.png"))
        XCTAssertEqual(StripStorage.migrateLegacyCache(base: base), 0)
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent(".hidden.png").path))
        XCTAssertTrue(fm.fileExists(atPath: old2.appendingPathComponent(".hidden.png").path))
    }
    
    func testStaleOwnLocationDetection() {
        let real = StripStorage.defaultBase
        XCTAssertTrue(InboxManager.isStaleOwnLocation(StripStorage.inboxDirectory(base: real).path))
        XCTAssertTrue(InboxManager.isStaleOwnLocation(StripStorage.legacyInboxDirectory(base: real).path))
        XCTAssertFalse(InboxManager.isStaleOwnLocation(nil))
        XCTAssertFalse(InboxManager.isStaleOwnLocation(""))
        XCTAssertFalse(InboxManager.isStaleOwnLocation(NSHomeDirectory() + "/Desktop"))
    }
    
    @MainActor
    func testTestHostNeverUsesRealApplicationSupport() {
        XCTAssertTrue(StripStorage.isRunningTests)
        let realSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        XCTAssertFalse(StripManager.screenshotsDirectory.path.hasPrefix(realSupport))
        XCTAssertFalse(StripManager.inboxDirectory.path.hasPrefix(realSupport))
        XCTAssertNotEqual(StripManager.shared.defaults, UserDefaults.standard, "El host de tests no usa los ajustes reales")
    }
    
    @MainActor
    func testCachedFileNameIsLanguageIndependent() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let url = try XCTUnwrap(StripManager.shared.saveToCache(cgImage: try XCTUnwrap(ctx.makeImage())))
        defer { try? fm.removeItem(at: url) }
        XCTAssertNotNil(url.lastPathComponent.range(of: #"^Screenshot-\d{4}-\d{2}-\d{2}-\d{6}\.png$"#, options: .regularExpression), url.lastPathComponent)
    }
}
