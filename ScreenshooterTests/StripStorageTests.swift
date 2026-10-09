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
}
