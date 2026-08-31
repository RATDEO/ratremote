import XCTest
@testable import RatRemote

final class ClickWheelGestureArbitratorTests: XCTestCase {
    func testRadialSwipeNeverEmitsBufferedScroll() {
        var arbitrator = ClickWheelGestureArbitrator()
        let frames: [(angle: Double, previousRadius: Double, radius: Double)] = [
            (0.020, 0.46, 0.39),
            (-0.015, 0.39, 0.31),
            (0.025, 0.31, 0.22),
            (-0.030, 0.22, 0.12),
            (0.040, 0.12, 0.08),
            (-0.025, 0.08, 0.18),
            (0.018, 0.18, 0.30)
        ]

        for frame in frames {
            XCTAssertNil(
                arbitrator.consume(
                    deltaAngle: frame.angle,
                    previousRadius: frame.previousRadius,
                    currentRadius: frame.radius,
                    scrollAmount: frame.angle * -80
                )
            )
        }
        XCTAssertFalse(arbitrator.isCommitted)
    }

    func testCircularMovementCommitsAndFlushesBufferedScroll() {
        var arbitrator = ClickWheelGestureArbitrator()
        var emitted: [Double] = []

        for _ in 0..<6 {
            if let amount = arbitrator.consume(
                deltaAngle: 0.04,
                previousRadius: 0.43,
                currentRadius: 0.43,
                scrollAmount: -3.2
            ) {
                emitted.append(amount)
            }
        }

        XCTAssertTrue(arbitrator.isCommitted)
        XCTAssertFalse(emitted.isEmpty)
        XCTAssertEqual(emitted.reduce(0, +), -19.2, accuracy: 0.001)
    }

    func testDirectionReversalsRemainBuffered() {
        var arbitrator = ClickWheelGestureArbitrator()
        for angle in [0.05, -0.05, 0.05, -0.05, 0.05, -0.05] {
            XCTAssertNil(
                arbitrator.consume(
                    deltaAngle: angle,
                    previousRadius: 0.42,
                    currentRadius: 0.42,
                    scrollAmount: angle * -80
                )
            )
        }
        XCTAssertFalse(arbitrator.isCommitted)
    }
}
