import Foundation

struct RemoteClickStabilizer {
    enum Motion: Equatable {
        case suppressed
        case beginDrag(dx: Double, dy: Double)
        case drag(dx: Double, dy: Double)
    }

    enum Release: Equatable {
        case none
        case click
        case endDrag
    }

    private(set) var isPressed = false
    private(set) var isDragging = false
    private var accumulatedDX = 0.0
    private var accumulatedDY = 0.0

    let dragActivationDistance: Double
    let dragActivationDelay: TimeInterval

    init(dragActivationDistance: Double = 44, dragActivationDelay: TimeInterval = 0.16) {
        self.dragActivationDistance = dragActivationDistance
        self.dragActivationDelay = dragActivationDelay
    }

    mutating func beginPress() -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        isDragging = false
        accumulatedDX = 0
        accumulatedDY = 0
        return true
    }

    mutating func move(dx: Double, dy: Double, pressedDuration: TimeInterval) -> Motion {
        guard isPressed else { return .drag(dx: dx, dy: dy) }
        if isDragging {
            return .drag(dx: dx, dy: dy)
        }

        accumulatedDX += dx
        accumulatedDY += dy
        let distance = hypot(accumulatedDX, accumulatedDY)
        guard pressedDuration >= dragActivationDelay, distance >= dragActivationDistance else {
            return .suppressed
        }

        isDragging = true
        let result = Motion.beginDrag(dx: accumulatedDX, dy: accumulatedDY)
        accumulatedDX = 0
        accumulatedDY = 0
        return result
    }

    mutating func endPress() -> Release {
        guard isPressed else { return .none }
        let result: Release = isDragging ? .endDrag : .click
        reset()
        return result
    }

    mutating func reset() {
        isPressed = false
        isDragging = false
        accumulatedDX = 0
        accumulatedDY = 0
    }
}
