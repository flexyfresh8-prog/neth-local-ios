import SwiftUI

struct ComposerOptions<Rows: View>: View {
    let title: String
    let rowCount: Int
    let heightLimit: CGFloat
    let close: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NethPalette.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NethPress())
                .accessibilityLabel("Close \(title.lowercased())")
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.leading, 14)
            .padding(.trailing, 3)

            ScrollView {
                LazyVStack(spacing: 3) { rows() }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(heightLimit, CGFloat(rowCount) * 60 + 6))
        }
        .background(NethPalette.inset, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(NethPalette.violet.opacity(0.30))
            .allowsHitTesting(false))
    }
}

struct ComposerChoice: View {
    let title: String
    let detail: String
    let symbol: String
    var selected = false
    let order: Int
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? NethPalette.lilac : NethPalette.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NethPalette.text)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(NethPalette.muted)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NethPalette.violet)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? NethPalette.violetSurface : NethPalette.rail, in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(NethPress())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .opacity(revealed || reduceMotion ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : -6)
        .allowsHitTesting(revealed || reduceMotion)
        .accessibilityHidden(!revealed && !reduceMotion)
        .animation(reduceMotion ? nil : NethMotion.reveal, value: revealed)
        .task(id: reduceMotion) {
            if !reduceMotion && !revealed {
                try? await Task.sleep(for: .milliseconds(20 + min(order, 6) * 28))
            }
            if !Task.isCancelled { revealed = true }
        }
    }
}
