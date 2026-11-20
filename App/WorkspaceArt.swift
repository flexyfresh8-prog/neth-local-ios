import SwiftUI

struct WorkspaceBackdrop: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let spacing: CGFloat = 13
            var dots = Path()
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.43)
            context.fill(dots, with: .radialGradient(
                Gradient(colors: [NethPalette.violet.opacity(0.21), NethPalette.muted.opacity(0.07), .clear]),
                center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.72
            ))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WorkspaceScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    // Each character is a square in the planet's light, shadow, or ring.
    private static let planet = [
        "          ++          ",
        "        ++##++        ",
        "       +#####::       ",
        "      +####:::::      ",
        "     +###:::::::..    ",
        "     +##::::::..: .   ",
        "     ++:::::..::..    ",
        "    .:::..::::::      ",
        "   . .:::::::::       ",
        "    ... ::::::        ",
        "         ::::         "
    ]

    private static let stars = [(28, 9), (39, 17), (54, 5), (62, 13), (72, 23), (82, 8), (110, 18), (117, 7)]
    private static let farRidge = [5, 7, 9, 12, 13, 11, 9, 8, 10, 13, 16, 18, 17, 14, 11, 8, 7, 9, 10, 8, 6, 5]
    private static let nearRidge = [4, 4, 5, 6, 8, 9, 8, 6, 5, 5, 6, 8, 7, 5, 4, 3, 4, 5, 6, 6, 4, 3]

    var body: some View {
        GeometryReader { bounds in
            let compact = bounds.size.width < 370
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [NethPalette.violetSurface, NethPalette.inset, NethPalette.canvas],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                sky
                beacon
                    .position(x: bounds.size.width * 0.72, y: bounds.size.height * 0.29)
                NethMascot(compact: compact)
                    .background {
                        RadialGradient(colors: [NethPalette.violet.opacity(0.20), .clear], center: .center,
                                       startRadius: 12, endRadius: 100)
                            .padding(-9)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, compact ? 8 : 27)
                    .padding(.bottom, 14)
            }
        }
        .frame(height: 204)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LinearGradient(colors: [NethPalette.violet.opacity(0.43), NethPalette.border,
                                                       NethPalette.border.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
    }

    private var beacon: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(NethPalette.lilac)
            .phaseAnimator(reduceMotion || phase != .active ? [0.72] : [0.78, 0.30, 1.0]) { signal, brightness in
                signal.opacity(brightness)
            } animation: { _ in .easeInOut(duration: 1.65) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var sky: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let unit = min(size.width / 124, size.height / 30)
            let origin = CGPoint(x: (size.width - unit * 124) / 2, y: size.height - unit * 30)
            func tile(_ x: Int, _ y: Int, width: Int = 1, height: Int = 1) -> CGRect {
                CGRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit,
                       width: CGFloat(width) * unit, height: CGFloat(height) * unit)
            }

            var pinpoints = Path()
            for (x, y) in Self.stars { pinpoints.addRect(tile(x, y)) }
            context.fill(pinpoints, with: .color(NethPalette.muted.opacity(0.58)))
            for (x, y) in [(50, 8), (113, 5)] {
                var star = Path()
                star.addRect(tile(x - 1, y, width: 3))
                star.addRect(tile(x, y - 1, height: 3))
                context.fill(star, with: .color(NethPalette.violet.opacity(0.72)))
            }

            let colors: [(Character, Color)] = [
                ("#", NethPalette.text.opacity(0.88)), ("+", NethPalette.muted),
                (":", NethPalette.violetSurface.opacity(0.94)), (".", NethPalette.violet.opacity(0.70))
            ]
            for (character, color) in colors {
                var pixels = Path()
                for (row, line) in Self.planet.enumerated() {
                    for (column, pixel) in line.enumerated() where pixel == character {
                        pixels.addRect(tile(89 + column, 4 + row))
                    }
                }
                context.fill(pixels, with: .color(color))
            }

            for (ridge, color) in [(Self.farRidge, NethPalette.violetSurface.opacity(0.72)),
                                   (Self.nearRidge, NethPalette.surface)] {
                var pixels = Path()
                for (index, height) in ridge.enumerated() {
                    pixels.addRect(tile(13 + 5 * index, 30 - height, width: 5, height: height))
                }
                context.fill(pixels, with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
