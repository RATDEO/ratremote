import Foundation

struct ClickWheelGestureArbitrator {
    private(set) var isCommitted = false
    private var pendingScrollAmount = 0.0
    private var tangentialTravel = 0.0
    private var radialTravel = 0.0
    private var signedAngularTravel = 0.0
    private var absoluteAngularTravel = 0.0

    private let minimumTangentialTravel = 0.055
    private let minimumAngularTravel = 0.14
    private let minimumDirectionConsistency = 0.72
    private let tangentialToRadialRatio = 1.45

    mutating func consume(
        deltaAngle: Double,
        previousRadius: Double,
        currentRadius: Double,
        scrollAmount: Double
    ) -> Double? {
        guard deltaAngle.isFinite,
              previousRadius.isFinite,
              currentRadius.isFinite,
              scrollAmount.isFinite else {
            return nil
        }

        if isCommitted {
            return abs(scrollAmount) >= 0.5 ? scrollAmount : nil
        }

        pendingScrollAmount += scrollAmount
        signedAngularTravel += deltaAngle
        absoluteAngularTravel += abs(deltaAngle)
        let averageRadius = max(0.01, (previousRadius + currentRadius) / 2)
        tangentialTravel += averageRadius * abs(deltaAngle)
        radialTravel += abs(currentRadius - previousRadius)

        let directionConsistency = absoluteAngularTravel > 0
            ? abs(signedAngularTravel) / absoluteAngularTravel
            : 0
        let isCircular = absoluteAngularTravel >= minimumAngularTravel &&
            tangentialTravel >= minimumTangentialTravel &&
            tangentialTravel >= radialTravel * tangentialToRadialRatio &&
            directionConsistency >= minimumDirectionConsistency

        guard isCircular else { return nil }
        isCommitted = true
        let amount = pendingScrollAmount
        pendingScrollAmount = 0
        return abs(amount) >= 0.5 ? amount : nil
    }

    mutating func reset() {
        isCommitted = false
        pendingScrollAmount = 0
        tangentialTravel = 0
        radialTravel = 0
        signedAngularTravel = 0
        absoluteAngularTravel = 0
    }
}
