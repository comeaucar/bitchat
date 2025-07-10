import XCTest
@testable import CoreMesh

final class CoreMeshTests: XCTestCase {
    func testVersionNotEmpty() {
        XCTAssertFalse(CoreMesh.version.isEmpty)
    }
}
