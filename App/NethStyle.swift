import SwiftUI

enum NethPalette {
    static let canvas = Color(white: 0.075)
    static let rail = Color(white: 0.10)
    static let surface = Color(white: 0.13)
    static let inset = Color(white: 0.095)
    static let selected = Color(white: 0.21)
    static let border = Color(white: 0.24)
    static let muted = Color(white: 0.65)
    static let text = Color(white: 0.94)
    static let violet = Color(red: 0.77, green: 0.67, blue: 0.96)
}

enum NethMotion {
    static let press = Animation.easeOut(duration: 0.14)
    static let fade = Animation.easeInOut(duration: 0.19)
    static let reveal = Animation.smooth(duration: 0.25)
}

struct NethPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.74 : 1) : 0.46)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : NethMotion.press, value: configuration.isPressed)
    }
}

struct NethMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "     *     ").foregroundStyle(NethPalette.violet)
            Text(verbatim: "     |     ").foregroundStyle(NethPalette.muted)
            Text(verbatim: " .---+---. ")
            Text(verbatim: blinking ? "[| -   - |]" : "[| o   o |]")
                .foregroundStyle(NethPalette.violet)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : NethMotion.press, value: blinking)
            Text(verbatim: " |   _   | ")
            Text(verbatim: " '-------' ")
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .foregroundStyle(NethPalette.text)
        .fixedSize()
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            blinking = false
            guard !reduceMotion else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    blinking = true
                    try await Task.sleep(for: .milliseconds(180))
                    blinking = false
                }
            } catch {}
        }
    }
}

struct NethMascotMark: View {
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let working = ["[o_o]", "[o_>]", "[>_o]", "[o_o]", "[-_-]"]

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.4)) { tick in
                    let frame = abs(Int(tick.date.timeIntervalSinceReferenceDate * 2.5) % Self.working.count)
                    Text(verbatim: Self.working[frame])
                }
            } else {
                Text(verbatim: active ? "[o.o]" : "[o_o]")
            }
        }
        .font(.system(.caption, design: .monospaced, weight: .semibold))
        .foregroundStyle(active ? NethPalette.violet : NethPalette.muted)
        .animation(reduceMotion ? nil : NethMotion.fade, value: active)
        .accessibilityHidden(true)
    }
}
