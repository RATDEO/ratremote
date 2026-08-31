import SwiftUI

/// Native SwiftUI interpretation of the dotted state animations from
/// https://orbs.jakubantalik.com. Each state keeps the same visual metaphor as
/// the original component while remaining lightweight enough for a floating panel.
enum ThinkingOrbState: String {
    case working
    case searching
    case solving
    case listening
    case composing
    case shaping

    var title: String {
        rawValue.capitalized + "\u{2026}"
    }
}

struct ThinkingOrb: View {
    let state: ThinkingOrbState
    var size: CGFloat = 64
    var speed: Double = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, canvasSize in
                let now = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate
                let time = now * stateSpeed * speed
                draw(in: &context, size: canvasSize, time: time)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title)
    }

    private var stateSpeed: Double {
        switch state {
        case .listening: 4.38
        case .working: 1.88
        case .searching: 2.02
        case .solving: 1.82
        case .composing: 2.34
        case .shaping: 2.40
        }
    }

    private var ink: Color {
        colorScheme == .dark ? .white : .black
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        switch state {
        case .listening: drawListening(in: &context, size: size, time: time)
        case .working: drawWorking(in: &context, size: size, time: time)
        case .searching: drawSearching(in: &context, size: size, time: time)
        case .solving: drawSolving(in: &context, size: size, time: time)
        case .composing: drawComposing(in: &context, size: size, time: time)
        case .shaping: drawShaping(in: &context, size: size, time: time)
        }
    }

    private func drawListening(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let count = sampleCount(28, compact: 16)
        for index in 0..<count {
            let angle = Double(index) / Double(count) * .pi * 2
            let ripple = 0.025 * sin(time * 1.5 + angle * 3)
            let radius = 0.29 + ripple
            let point = ProjectedPoint(
                x: size.width * (0.5 + cos(angle) * radius),
                y: size.height * (0.5 + sin(angle) * radius),
                z: 0.48 + 0.18 * sin(angle - time * 0.45)
            )
            let emphasis = 0.22 * (0.5 + 0.5 * sin(angle * 2 - time))
            dot(in: &context, at: point, size: size, depth: point.z, emphasis: emphasis, baseOpacity: 0.48, radiusScale: 0.62)
        }

        let innerCount = sampleCount(12, compact: 8)
        for index in 0..<innerCount {
            let angle = Double(index) / Double(innerCount) * .pi * 2 - time * 0.22
            let point = ProjectedPoint(
                x: size.width * (0.5 + cos(angle) * 0.16),
                y: size.height * (0.5 + sin(angle) * 0.16),
                z: 0.42
            )
            dot(in: &context, at: point, size: size, depth: point.z, emphasis: 0, baseOpacity: 0.25, radiusScale: 0.48)
        }
    }

    private func drawSearching(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let rings = sampleCount(17, compact: 8)
        let columns = sampleCount(44, compact: 20)
        for ring in 0...rings {
            let latitude = -.pi / 2 + Double(ring) / Double(rings) * .pi
            let count = max(3, Int(abs(cos(latitude)) * Double(columns)))
            for column in 0..<count {
                let longitude = Double(column) / Double(count) * .pi * 2
                let point = project(
                    x: cos(latitude) * cos(longitude) * 0.36,
                    y: sin(latitude) * 0.36,
                    z: cos(latitude) * sin(longitude) * 0.36,
                    rotation: time * 0.5,
                    tilt: 0.42,
                    size: size
                )
                let scanAngle = atan2(sin(longitude - time * 1.7), cos(longitude - time * 1.7))
                let scan = exp(-(scanAngle * scanAngle) / 0.18) * max(0, point.z)
                dot(in: &context, at: point, size: size, depth: point.z, emphasis: scan, baseOpacity: 0.42)
            }
        }
    }

    private func drawSolving(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let rings = sampleCount(15, compact: 7)
        let columns = sampleCount(40, compact: 18)
        for ring in 0...rings {
            let latitude = -.pi / 2 + Double(ring) / Double(rings) * .pi
            let count = max(3, Int(abs(cos(latitude)) * Double(columns)))
            for column in 0..<count {
                let longitude = Double(column) / Double(count) * .pi * 2
                var x = cos(latitude) * cos(longitude)
                var y = sin(latitude)
                var z = cos(latitude) * sin(longitude)
                let band = floor((y + 1) * 3).truncatingRemainder(dividingBy: 3)
                let turn = sin(time * 0.7 + band * 2.1) * 0.36
                let nextX = x * cos(turn) + z * sin(turn)
                z = -x * sin(turn) + z * cos(turn)
                x = nextX
                y += 0.018 * sin(time * 2 + Double(ring))
                let point = project(x: x * 0.36, y: y * 0.36, z: z * 0.36, rotation: time * 0.42, tilt: 0.35, size: size)
                dot(in: &context, at: point, size: size, depth: point.z, emphasis: abs(sin(turn)) * 0.22)
            }
        }
    }

    private func drawWorking(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let count = sampleCount(118, compact: 38)
        let goldenAngle = .pi * (3 - sqrt(5.0))
        for index in 0..<count {
            let vertical = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let radial = sqrt(max(0, 1 - vertical * vertical))
            let longitude = Double(index) * goldenAngle
            let drift = 0.035 * sin(time * 0.72 + longitude * 2.4)
            let sphereRadius = 0.32 + drift
            let point = project(
                x: radial * cos(longitude) * sphereRadius,
                y: vertical * sphereRadius,
                z: radial * sin(longitude) * sphereRadius,
                rotation: time * 0.16,
                tilt: 0.28 + 0.08 * sin(time * 0.12),
                size: size
            )
            let shimmer = max(0, sin(longitude * 1.7 - time * 0.55)) * 0.24
            dot(in: &context, at: point, size: size, depth: point.z, emphasis: shimmer, baseOpacity: 0.32, radiusScale: 0.72)
        }
    }

    private func drawComposing(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let lanes = sampleCount(15, compact: 7)
        let segments = sampleCount(88, compact: 32)
        for lane in 0..<lanes {
            let offset = (Double(lane) - Double(lanes - 1) / 2) * 0.012
            for segment in 0..<segments {
                let angle = Double(segment) / Double(segments) * .pi * 2
                let wobble = 0.035 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                    + 0.016 * sin(angle * 5 + time * 1.1)
                let latitude = offset + wobble
                let point = project(
                    x: cos(angle) * cos(latitude) * 0.35,
                    y: sin(latitude) * 0.35,
                    z: sin(angle) * cos(latitude) * 0.35,
                    rotation: 0.22,
                    tilt: 0.58 + 0.2 * sin(time * 0.18),
                    size: size
                )
                dot(in: &context, at: point, size: size, depth: point.z, emphasis: 0.12, baseOpacity: 0.38, radiusScale: 0.85)
            }
        }
    }

    private func drawShaping(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let shapes: [[CGPoint]] = [
            stride(from: 0.0, to: .pi * 2, by: .pi / 20).map { CGPoint(x: cos($0) * 0.24, y: sin($0) * 0.24) },
            [CGPoint(x: 0, y: -0.26), CGPoint(x: 0.24, y: 0.16), CGPoint(x: -0.24, y: 0.16)],
            [CGPoint(x: -0.2, y: -0.2), CGPoint(x: 0.2, y: -0.2), CGPoint(x: 0.2, y: 0.2), CGPoint(x: -0.2, y: 0.2)]
        ]
        let duration = 2.3
        let position = time.truncatingRemainder(dividingBy: duration * 3) / duration
        let index = Int(floor(position)) % shapes.count
        let progress = smooth(position - floor(position))
        let from = sampledPath(shapes[index], count: sampleCount(44, compact: 20))
        let to = sampledPath(shapes[(index + 1) % shapes.count], count: from.count)
        for item in from.indices {
            let x = from[item].x + (to[item].x - from[item].x) * progress
            let y = from[item].y + (to[item].y - from[item].y) * progress
            let point = ProjectedPoint(x: size.width * (0.5 + x), y: size.height * (0.5 + y), z: 0.5)
            dot(in: &context, at: point, size: size, depth: 0.5, emphasis: 0.2, radiusScale: 0.78)
        }
    }

    private func sampleCount(_ regular: Int, compact: Int) -> Int {
        size < 36 ? compact : regular
    }

    private func dot(
        in context: inout GraphicsContext,
        at point: ProjectedPoint,
        size: CGSize,
        depth: Double,
        emphasis: Double,
        baseOpacity: Double = 0.55,
        radiusScale: Double = 1
    ) {
        let scale = min(size.width, size.height) / 64
        let normalizedDepth = min(1, max(0, depth))
        let radius = max(0.38, (0.6 + 1.55 * normalizedDepth + emphasis) * pow(scale, 0.62) * radiusScale)
        let opacity = min(1, baseOpacity + normalizedDepth * 0.42 + emphasis * 0.28)
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(ink.opacity(opacity)))
    }

    private func project(x: Double, y: Double, z: Double, rotation: Double, tilt: Double, size: CGSize) -> ProjectedPoint {
        let rotatedX = x * cos(rotation) + z * sin(rotation)
        let rotatedZ = -x * sin(rotation) + z * cos(rotation)
        let tiltedY = y * cos(tilt) - rotatedZ * sin(tilt)
        let tiltedZ = y * sin(tilt) + rotatedZ * cos(tilt)
        return ProjectedPoint(
            x: size.width * (0.5 + rotatedX),
            y: size.height * (0.5 - tiltedY),
            z: min(1, max(0, 0.5 + tiltedZ * 1.35))
        )
    }

    private func orbitPoint(angle: Double, radius: Double, tilt: Double, rotation: Double, size: CGSize) -> ProjectedPoint {
        project(
            x: cos(angle) * radius,
            y: sin(angle) * radius * cos(tilt),
            z: sin(angle) * radius * sin(tilt),
            rotation: rotation,
            tilt: 0.25,
            size: size
        )
    }

    private func pseudoRandom(_ value: Double, _ salt: Double) -> Double {
        let raw = sin(value * 12.9898 + salt * 78.233) * 43_758.5453
        return raw - floor(raw)
    }

    private func smooth(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private func sampledPath(_ vertices: [CGPoint], count: Int) -> [CGPoint] {
        guard vertices.count > 1 else { return vertices }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in vertices.indices {
            let next = vertices[(index + 1) % vertices.count]
            let length = hypot(next.x - vertices[index].x, next.y - vertices[index].y)
            lengths.append(length)
            total += length
        }
        return (0..<count).map { sample in
            var distance = CGFloat(sample) / CGFloat(count) * total
            var edge = 0
            while edge < lengths.count - 1, distance > lengths[edge] {
                distance -= lengths[edge]
                edge += 1
            }
            let start = vertices[edge]
            let end = vertices[(edge + 1) % vertices.count]
            let amount = lengths[edge] > 0 ? distance / lengths[edge] : 0
            return CGPoint(x: start.x + (end.x - start.x) * amount, y: start.y + (end.y - start.y) * amount)
        }
    }
}

private struct ProjectedPoint {
    let x: Double
    let y: Double
    let z: Double
}

extension RemoteCoordinator {
    var activityOrbState: ThinkingOrbState? {
        if isRecording { return .listening }

        if isAutomationRunning {
            let value = automationStatus.lowercased()
            if value.contains("reading") || value.contains("observing") { return .searching }
            if value.contains("planning") { return .solving }
            if value.contains("acting") || value.contains("approved") { return .shaping }
            return .working
        }

        if status == "Transcribing" {
            let value = insertionStatus.lowercased()
            if value.contains("reading") || value.contains("locating") { return .searching }
            if value.contains("agent server") || value.contains("command server") { return .solving }
            return .composing
        }
        return nil
    }

    var activityOrbLabel: String? {
        if isRecording { return "Listening\u{2026}" }
        if isAutomationRunning { return automationStatus + (automationStatus.hasSuffix("\u{2026}") ? "" : "\u{2026}") }
        if status == "Transcribing" {
            let value = insertionStatus
            if value == "Reading screen" { return "Searching\u{2026}" }
            if value == "Agent server" || value == "Command server" { return "Solving\u{2026}" }
            if value.lowercased().contains("locating") { return value + "\u{2026}" }
            return "Transcribing\u{2026}"
        }
        return nil
    }
}
