import XCTest
@testable import RatRemote

final class RemoteSwipeRecognizerTests: XCTestCase {
    private let capturedSensitivity = 3.3294128865400476

    func testCapturedCalibrationSwipesAreRecognized() {
        let captures: [(RemoteSwipeMetrics, RemoteSwipeDirection)] = [
            (metrics(start: (0.9563964, 0.5394595), end: (0.2010811, 0.5971171), span: (0.7553153, 0.0735135), pathLength: 0.7628592, duration: 0.2175211), .left),
            (metrics(start: (0.0893694, 0.6021621), end: (0.8497297, 0.5812613), span: (0.7603603, 0.0281081), pathLength: 0.7625862, duration: 0.2397450), .right),
            (metrics(start: (0.9059460, 0.5178379), end: (0.1679279, 0.5632433), span: (0.7380180, 0.0699099), pathLength: 0.7458644, duration: 0.2411370), .left),
            (metrics(start: (0.4576577, 0.9091892), end: (0.5037838, 0.1848649), span: (0.0562162, 0.7243243), pathLength: 0.7348441, duration: 0.2239571), .up),
            (metrics(start: (0.5153153, 0.1099099), end: (0.5282883, 0.7996396), span: (0.0165766, 0.6897298), pathLength: 0.6918811, duration: 0.1670390), .down)
        ]

        for (capture, expectedDirection) in captures {
            XCTAssertEqual(RemoteSwipeRecognizer.evaluate(capture).direction, expectedDirection)
        }
    }

    func testShortCentralPointerMovementIsRejected() {
        let movement = RemoteSwipeMetrics(
            startX: 0.42, startY: 0.48,
            endX: 0.65, endY: 0.50,
            minX: 0.42, minY: 0.48,
            maxX: 0.65, maxY: 0.50,
            pathLength: 0.24,
            duration: 0.25,
            sensitivity: AppSettings.maxSwipeSensitivity
        )

        let evaluation = RemoteSwipeRecognizer.evaluate(movement)
        XCTAssertNil(evaluation.direction)
        XCTAssertTrue(evaluation.failures.contains("travel"))
        XCTAssertTrue(evaluation.failures.contains("edge-coverage"))
    }

    func testSlowCurvedMovementIsRejected() {
        let movement = RemoteSwipeMetrics(
            startX: 0.10, startY: 0.40,
            endX: 0.82, endY: 0.50,
            minX: 0.10, minY: 0.25,
            maxX: 0.86, maxY: 0.68,
            pathLength: 1.30,
            duration: 1.10,
            sensitivity: AppSettings.maxSwipeSensitivity
        )

        let evaluation = RemoteSwipeRecognizer.evaluate(movement)
        XCTAssertNil(evaluation.direction)
        XCTAssertTrue(evaluation.failures.contains("path-straightness"))
        XCTAssertTrue(evaluation.failures.contains("timing"))
    }

    func testSensitivityChangesRecognitionAcrossFullRange() {
        let low = RemoteSwipeMetrics(
            startX: 0.25, startY: 0.50,
            endX: 0.75, endY: 0.52,
            minX: 0.25, minY: 0.50,
            maxX: 0.75, maxY: 0.52,
            pathLength: 0.51,
            duration: 0.20,
            sensitivity: AppSettings.minSwipeSensitivity
        )
        let high = RemoteSwipeMetrics(
            startX: low.startX, startY: low.startY,
            endX: low.endX, endY: low.endY,
            minX: low.minX, minY: low.minY,
            maxX: low.maxX, maxY: low.maxY,
            pathLength: low.pathLength,
            duration: low.duration,
            sensitivity: AppSettings.maxSwipeSensitivity
        )

        XCTAssertNil(RemoteSwipeRecognizer.evaluate(low).direction)
        XCTAssertEqual(RemoteSwipeRecognizer.evaluate(high).direction, .right)
    }

    private func metrics(
        start: (Double, Double),
        end: (Double, Double),
        span: (Double, Double),
        pathLength: Double,
        duration: TimeInterval
    ) -> RemoteSwipeMetrics {
        RemoteSwipeMetrics(
            startX: start.0,
            startY: start.1,
            endX: end.0,
            endY: end.1,
            minX: min(start.0, end.0),
            minY: min(start.1, end.1),
            maxX: min(1, min(start.0, end.0) + span.0),
            maxY: min(1, min(start.1, end.1) + span.1),
            pathLength: pathLength,
            duration: duration,
            sensitivity: capturedSensitivity
        )
    }
}
