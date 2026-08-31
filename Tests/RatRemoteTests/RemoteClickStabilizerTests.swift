import XCTest
@testable import RatRemote

final class RemoteClickStabilizerTests: XCTestCase {
    func testShortPressWithJitterBecomesClick() {
        var stabilizer = RemoteClickStabilizer()

        XCTAssertTrue(stabilizer.beginPress())
        XCTAssertEqual(stabilizer.move(dx: 13, dy: -9, pressedDuration: 0.04), .suppressed)
        XCTAssertEqual(stabilizer.move(dx: -4, dy: 7, pressedDuration: 0.10), .suppressed)
        XCTAssertEqual(stabilizer.endPress(), .click)
    }

    func testLargeMovementBeforeDelayStillBecomesClick() {
        var stabilizer = RemoteClickStabilizer()

        XCTAssertTrue(stabilizer.beginPress())
        XCTAssertEqual(stabilizer.move(dx: 60, dy: 0, pressedDuration: 0.08), .suppressed)
        XCTAssertEqual(stabilizer.endPress(), .click)
    }

    func testDeliberateHeldMovementBeginsAndEndsDrag() {
        var stabilizer = RemoteClickStabilizer()

        XCTAssertTrue(stabilizer.beginPress())
        XCTAssertEqual(stabilizer.move(dx: 20, dy: 0, pressedDuration: 0.10), .suppressed)
        XCTAssertEqual(stabilizer.move(dx: 30, dy: 0, pressedDuration: 0.20), .beginDrag(dx: 50, dy: 0))
        XCTAssertEqual(stabilizer.move(dx: 8, dy: -3, pressedDuration: 0.24), .drag(dx: 8, dy: -3))
        XCTAssertEqual(stabilizer.endPress(), .endDrag)
    }

    func testDuplicatePressAndReleaseAreIgnored() {
        var stabilizer = RemoteClickStabilizer()

        XCTAssertTrue(stabilizer.beginPress())
        XCTAssertFalse(stabilizer.beginPress())
        XCTAssertEqual(stabilizer.endPress(), .click)
        XCTAssertEqual(stabilizer.endPress(), .none)
    }
}
