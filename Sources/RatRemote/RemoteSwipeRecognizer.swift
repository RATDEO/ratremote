import Foundation

enum RemoteSwipeDirection: String, Codable, Equatable {
    case left
    case right
    case up
    case down
}

struct RemoteSwipeMetrics {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let pathLength: Double
    let duration: TimeInterval
    let sensitivity: Double
}

struct RemoteSwipeEvaluation {
    let direction: RemoteSwipeDirection?
    let candidateDirection: RemoteSwipeDirection
    let failures: [String]
    let travelThreshold: Double
    let edgeInset: Double
    let straightness: Double

    var summary: String {
        if let direction {
            return "recognized \(direction.rawValue)"
        }
        return "rejected \(candidateDirection.rawValue): \(failures.joined(separator: ", "))"
    }
}

enum RemoteSwipeRecognizer {
    private static let minimumDuration: TimeInterval = 0.04
    private static let maximumDuration: TimeInterval = 0.60
    private static let minimumStraightness = 0.80
    private static let minimumDominanceRatio = 2.0

    static func evaluate(_ metrics: RemoteSwipeMetrics) -> RemoteSwipeEvaluation {
        let sensitivityRange = AppSettings.maxSwipeSensitivity - AppSettings.minSwipeSensitivity
        let normalizedSensitivity = min(
            1,
            max(0, (metrics.sensitivity - AppSettings.minSwipeSensitivity) / sensitivityRange)
        )

        let travelThreshold = 0.72 - (0.30 * normalizedSensitivity)
        let edgeInset = 0.18 + (0.13 * normalizedSensitivity)
        let dx = metrics.endX - metrics.startX
        let dy = metrics.endY - metrics.startY
        let absDx = abs(dx)
        let absDy = abs(dy)
        let displacement = hypot(dx, dy)
        let straightness = metrics.pathLength > 0 ? displacement / metrics.pathLength : 0
        let isHorizontal = absDx >= absDy
        let primaryTravel = isHorizontal ? absDx : absDy
        let perpendicularTravel = isHorizontal ? absDy : absDx

        let candidateDirection: RemoteSwipeDirection
        if isHorizontal {
            candidateDirection = dx >= 0 ? .right : .left
        } else {
            candidateDirection = dy >= 0 ? .down : .up
        }

        var failures: [String] = []
        if primaryTravel < travelThreshold {
            failures.append("travel")
        }
        if primaryTravel < max(0.10, perpendicularTravel * minimumDominanceRatio) {
            failures.append("axis-dominance")
        }
        if straightness < minimumStraightness {
            failures.append("path-straightness")
        }
        if metrics.duration < minimumDuration || metrics.duration > maximumDuration {
            failures.append("timing")
        }
        if !hasEdgeCoverage(candidateDirection, metrics: metrics, edgeInset: edgeInset) {
            failures.append("edge-coverage")
        }

        return RemoteSwipeEvaluation(
            direction: failures.isEmpty ? candidateDirection : nil,
            candidateDirection: candidateDirection,
            failures: failures,
            travelThreshold: travelThreshold,
            edgeInset: edgeInset,
            straightness: straightness
        )
    }

    private static func hasEdgeCoverage(
        _ direction: RemoteSwipeDirection,
        metrics: RemoteSwipeMetrics,
        edgeInset: Double
    ) -> Bool {
        switch direction {
        case .right:
            return metrics.startX <= edgeInset && metrics.maxX >= 1 - edgeInset
        case .left:
            return metrics.startX >= 1 - edgeInset && metrics.minX <= edgeInset
        case .down:
            return metrics.startY <= edgeInset && metrics.maxY >= 1 - edgeInset
        case .up:
            return metrics.startY >= 1 - edgeInset && metrics.minY <= edgeInset
        }
    }
}
