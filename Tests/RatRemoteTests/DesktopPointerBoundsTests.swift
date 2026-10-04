import XCTest
@testable import RatRemote

final class DesktopPointerBoundsTests: XCTestCase {
    func testPointerCanCrossOntoDisplaysOnEitherSide() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: -1200, y: 0, width: 1200, height: 900),
                       CGRect(x: 1000, y: 0, width: 1600, height: 900)]
        for point in [CGPoint(x: -10, y: 400), CGPoint(x: 1010, y: 400)] {
            XCTAssertEqual(DesktopPointerBounds.constrain(point, to: screens), point)
        }
    }

    func testDisplayAboveLaptopAndGapClamping() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 0, y: -900, width: 1600, height: 900)]
        XCTAssertEqual(DesktopPointerBounds.constrain(CGPoint(x: 500, y: -10), to: screens), CGPoint(x: 500, y: -10))
        XCTAssertEqual(DesktopPointerBounds.constrain(CGPoint(x: 1100, y: 400), to: screens), CGPoint(x: 999, y: 400))
    }
}
