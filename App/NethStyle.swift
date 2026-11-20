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
    static let lilac = Color(red: 0.87, green: 0.80, blue: 0.98)
    static let violetSurface = Color(red: 0.16, green: 0.13, blue: 0.22)
}

enum NethMotion {
    static let press = Animation.snappy(duration: 0.17)
    static let fade = Animation.easeInOut(duration: 0.19)
    static let reveal = Animation.smooth(duration: 0.30)
    static let open = Animation.spring(response: 0.36, dampingFraction: 0.82)

    static let panel = AnyTransition.asymmetric(
        insertion: .offset(y: -9).combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .opacity),
        removal: .offset(y: -4).combined(with: .opacity)
    )
    static let rise = AnyTransition.offset(y: 8).combined(with: .opacity)
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
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @State private var gaze: Look = .forward
    @State private var greeting = false
    @State private var taps = 0

    private enum Look: Equatable {
        case forward, left, right, blink, happy

        var eyes: String {
            switch self {
            case .forward: "o o"
            case .left: "< o"
            case .right: "o >"
            case .blink: "- -"
            case .happy: "^ ^"
            }
        }
    }

    private var animating: Bool { scene == .active && !reduceMotion }

    var body: some View {
        Button {
            greeting = true
            taps += 1
        } label: {
            rover(look: greeting ? .happy : gaze)
                .scaleEffect(greeting && !reduceMotion ? 1.04 : 1)
                .offset(y: greeting && !reduceMotion ? -5 : 0)
                .animation(reduceMotion ? nil : NethMotion.open, value: greeting)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(NethPress())
        .accessibilityLabel("Neth mascot")
        .accessibilityHint("Makes the mascot smile")
        .task(id: animating) {
            gaze = .forward
            guard animating else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(3200))
                    gaze = .right
                    try await Task.sleep(for: .milliseconds(550))
                    gaze = .forward
                    try await Task.sleep(for: .milliseconds(2400))
                    gaze = .left
                    try await Task.sleep(for: .milliseconds(400))
                    gaze = .blink
                    try await Task.sleep(for: .milliseconds(130))
                    gaze = .forward
                }
            } catch is CancellationError {
                return
            } catch { gaze = .forward }
        }
        .task(id: taps) {
            guard taps > 0 else { return }
            try? await Task.sleep(for: .milliseconds(1250))
            if !Task.isCancelled { greeting = false }
        }
    }

    private func rover(look: Look) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "       *       ").foregroundStyle(NethPalette.violet)
            Text(verbatim: "   .---+---.   ")
            Text(verbatim: " .-|.-----.|-. ")
            Text(verbatim: " | || \(look.eyes) || | ")
                .foregroundStyle(NethPalette.lilac)
                .contentTransition(.opacity)
            Text(verbatim: look == .happy ? " '-||  v  ||-' " : " '-||  _  ||-' ")
                .contentTransition(.opacity)
            Text(verbatim: "   |'-----'|   ")
            Text(verbatim: "   '---.---'   ")
            Text(verbatim: #"    __/ \__    "#).foregroundStyle(NethPalette.muted)
        }
        .font(.system(size: compact ? 13 : 17, weight: .semibold, design: .monospaced))
        .foregroundStyle(NethPalette.text)
        .fixedSize()
        .animation(reduceMotion ? nil : NethMotion.press, value: look)
    }
}

struct NethMascotMark: View {
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    private static let working = ["[o_o]", "[o_>]", "[^_^]", "[<_o]", "[-_-]", "[o_o]"]

    var body: some View {
        Group {
            if active && !reduceMotion && scene == .active {
                TimelineView(.periodic(from: .now, by: 0.34)) { tick in
                    let frame = abs(Int(tick.date.timeIntervalSinceReferenceDate / 0.34) % Self.working.count)
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
