import XCTest
@testable import GlyphVault

final class SharedHubTests: XCTestCase {
    func testSetReadClearAndFallback() {
        let suite = "test.glyph.hub.\(UUID().uuidString)", own = UserDefaults(suiteName: "own.\(suite)")!
        defer { UserDefaults().removePersistentDomain(forName: suite); own.removePersistentDomain(forName: "own.\(suite)") }
        XCTAssertNil(GlyphHub.address(fallbackKey: "vaultURL", suiteName: suite, fallback: own))
        own.set("http://old:1", forKey: "vaultURL")
        XCTAssertEqual(GlyphHub.address(fallbackKey: "vaultURL", suiteName: suite, fallback: own), "http://old:1")
        GlyphHub.setAddress(" http://new:2 ", suiteName: suite)
        XCTAssertEqual(GlyphHub.address(fallbackKey: "vaultURL", suiteName: suite, fallback: own), "http://new:2")
        GlyphHub.clearAddress(suiteName: suite)
        XCTAssertNil(GlyphHub.address(fallbackKey: "vaultURL", suiteName: suite, fallback: own))   // disconnected: not the old address
    }

    func testThreeWayResolve() {
        let suite = "test.glyph.hub3.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(GlyphHub.resolve(suiteName: suite) { "http://built:1" }, "http://built:1")   // never paired
        XCTAssertNil(GlyphHub.resolve(suiteName: suite) { nil })
        XCTAssertFalse(GlyphHub.isShared(suiteName: suite))
        GlyphHub.setAddress("http://studio.example:7071", suiteName: suite)
        XCTAssertEqual(GlyphHub.resolve(suiteName: suite) { "http://built:1" }, "http://studio.example:7071")
        XCTAssertTrue(GlyphHub.isShared(suiteName: suite))
        GlyphHub.clearAddress(suiteName: suite)
        XCTAssertNil(GlyphHub.resolve(suiteName: suite) { "http://built:1" })   // disconnected
        GlyphHub.setAddress("http://studio.example:7071", suiteName: suite)    // paired again
        XCTAssertEqual(GlyphHub.resolve(suiteName: suite) { "http://built:1" }, "http://studio.example:7071")
    }
}
