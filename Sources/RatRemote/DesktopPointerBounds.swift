import Foundation

enum DesktopPointerBounds {
    static func constrain(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        let displays = displays.filter { !$0.isEmpty }
        guard !displays.isEmpty else { return point }
        if displays.contains(where: { $0.contains(point) }) { return point }

        // Project onto the closest real display rather than the bounding rectangle,
        // which can contain inaccessible gaps between differently sized displays.
        return displays.map { bounds in
            CGPoint(
                x: min(bounds.maxX - 1, max(bounds.minX, point.x)),
                y: min(bounds.maxY - 1, max(bounds.minY, point.y))
            )
        }.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }
}
