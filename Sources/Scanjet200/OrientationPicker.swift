import SwiftUI
import ScanjetCore

struct OrientationSegmentedControl: View {
    @Binding var selection: ScanOrientation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ScanOrientation.allCases, id: \.self) { orientation in
                let selected = selection == orientation
                Button {
                    selection = orientation
                } label: {
                    // CGContext rotates counterclockwise; SwiftUI clockwise — negate so the icon matches the scan.
                    OrientationIcon(degrees: -Double(orientation.rawValue), selected: selected)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(minWidth: 36, minHeight: 28)
                        .background(
                            selected ? Color.accentColor.opacity(0.85) : Color.clear
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(orientation.accessibilityLabel)
                .tooltip(orientation.helpText)

                if orientation != ScanOrientation.allCases.last {
                    Divider().frame(height: 18)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.gray.opacity(0.35))
        )
        .fixedSize()
    }
}

private struct OrientationIcon: View {
    let degrees: Double
    let selected: Bool
    private let size: CGFloat = 16

    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(degrees))
            .frame(width: size, height: size)
    }
}

private extension ScanOrientation {
    var accessibilityLabel: String {
        switch self {
        case .deg0: return "Portrait"
        case .deg90: return "Landscape, rotated left on scanner"
        case .deg180: return "Portrait upside down"
        case .deg270: return "Landscape, rotated right on scanner"
        }
    }

    var helpText: String {
        switch self {
        case .deg0: return "Upright. The top of the page is toward the back of the scanner."
        case .deg90: return "Rotated 90°. The top of the page is toward the left."
        case .deg180: return "Upside down. The top of the page is toward the front of the scanner."
        case .deg270: return "Rotated 270°. The top of the page is toward the right."
        }
    }
}
