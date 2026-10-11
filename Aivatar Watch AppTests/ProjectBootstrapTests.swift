import XCTest
@testable import Aivatar_Watch_App

final class ProjectBootstrapTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(Bundle(for: ProjectBootstrapTests.self))
    }
}
