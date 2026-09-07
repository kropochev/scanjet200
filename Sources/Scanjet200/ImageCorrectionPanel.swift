import SwiftUI
import AppKit
import ScanjetCore

struct ImageCorrectionManualView: View {
    @Binding var correction: ImageCorrection

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                sliderRow("Brightness:", tooltip: "Lighten or darken the scan.") {
                    SunGlyph(filled: false, size: 11)
                } trailing: {
                    SunGlyph(filled: true, size: 15)
                } value: {
                    $correction.brightness
                }

                sliderRow("Tint:", tooltip: "Shift colour toward magenta or green.") {
                    Circle().fill(Color(red: 0.82, green: 0.18, blue: 0.62))
                        .frame(width: 9, height: 9)
                } trailing: {
                    Circle().fill(Color(red: 0.22, green: 0.72, blue: 0.28))
                        .frame(width: 9, height: 9)
                } value: {
                    $correction.tint
                }

                sliderRow("Temperature:", tooltip: "Shift colour toward cool blue or warm orange.") {
                    TemperatureGlyph(warm: false)
                } trailing: {
                    TemperatureGlyph(warm: true)
                } value: {
                    $correction.temperature
                }

                sliderRow("Saturation:", tooltip: "Move from grey toward stronger colours.") {
                    SaturationGlyph(vivid: false)
                } trailing: {
                    SaturationGlyph(vivid: true)
                } value: {
                    $correction.saturation
                }
            }

            Button("Restore Defaults") {
                var next = correction
                next.restoreDefaults()
                correction = next
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Divider()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func sliderRow<Leading: View, Trailing: View>(
        _ title: String,
        tooltip: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        value: () -> Binding<Double>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 96, alignment: .trailing)
            leading()
                .frame(width: 16, height: 16)
            TickSlider(value: value())
                .frame(minWidth: 80, idealHeight: 28)
            trailing()
                .frame(width: 16, height: 16)
        }
        .frame(maxWidth: .infinity)
        .tooltip(tooltip)
    }
}

struct TickSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.minValue = -1
        slider.maxValue = 1
        slider.doubleValue = value
        slider.numberOfTickMarks = 17
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.value = $value
        if abs(nsView.doubleValue - value) > 0.0005 {
            nsView.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

private struct SunGlyph: View {
    let filled: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: filled ? "sun.max.fill" : "sun.min")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.primary.opacity(filled ? 0.95 : 0.7))
    }
}

private struct TemperatureGlyph: View {
    let warm: Bool

    var body: some View {
        ZStack {
            Image(systemName: "sun.max")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
            Circle()
                .fill(warm
                      ? Color(red: 0.95, green: 0.55, blue: 0.12)
                      : Color(red: 0.28, green: 0.55, blue: 0.95))
                .frame(width: 5.5, height: 5.5)
                .offset(y: 0.2)
        }
        .frame(width: 16, height: 16)
    }
}

private struct SaturationGlyph: View {
    let vivid: Bool

    var body: some View {
        Canvas { context, size in
            let inset = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 2)
            let count = 5
            let gap: CGFloat = 0.8
            let barW = (inset.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let colors: [Color] = vivid
                ? [
                    Color(red: 0.85, green: 0.15, blue: 0.12),
                    Color(red: 0.95, green: 0.75, blue: 0.12),
                    Color(red: 0.18, green: 0.72, blue: 0.22),
                    Color(red: 0.12, green: 0.45, blue: 0.95),
                    Color(red: 0.55, green: 0.18, blue: 0.85)
                ]
                : (0..<count).map { i in
                    let g = 0.35 + 0.1 * Double(i)
                    return Color(white: g)
                }
            for i in 0..<count {
                let x = inset.minX + CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: inset.minY, width: max(1, barW), height: inset.height)
                context.fill(Path(rect), with: .color(colors[i]))
            }
            context.stroke(
                Path(roundedRect: inset.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 1),
                with: .color(Color.primary.opacity(0.35)),
                lineWidth: 0.6
            )
        }
        .frame(width: 15, height: 11)
    }
}
