import SQLite3
import XCTest
@testable import AFITCCore

final class BootstrapTests: XCTestCase {
    func testSQLite3LibraryAvailableAndCoreTypesWork() {
        let versionCStr = sqlite3_libversion()
        XCTAssertNotNil(versionCStr)
        let versionString = String(cString: versionCStr!)
        XCTAssertFalse(versionString.isEmpty, "SQLite version string should not be empty")

        let info = CatalogDatabaseInfo()
        XCTAssertEqual(info.sqliteVersion, versionString)
        XCTAssertEqual(info.schemaVersion, CatalogSchema.currentVersion)

        let photo = PhotoIdentity(relativePath: "test/path.jpg")
        XCTAssertEqual(photo.relativePath, "test/path.jpg")
    }
}
