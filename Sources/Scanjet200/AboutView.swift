import SwiftUI
import AppKit
import ScanjetCore

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text("Scanjet 200")
                    .font(.title2.weight(.semibold))
                Text("Version \(AppVersion.display)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Unofficial macOS driver for the HP Scanjet 200 flatbed scanner. HP never shipped a driver for modern macOS; the protocol was reconstructed from USB captures of the Windows driver.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                aboutRow("Scanner", "HP Scanjet 200")
                aboutRow("Chip", "Genesys GL848+")
                aboutRow("USB ID", "03f0:1c05")
                aboutRow("Optics", "2400 dpi CIS, 48-bit, A4")
                aboutRow("Bed", "about 218 × 297 mm")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 4) {
                Text("Not affiliated with HP, HP Inc., or Genesys Logic.")
                Text("scanjet200 is MIT. Bundled libusb is LGPL-2.1-or-later.")
                Text("HP, Scanjet, and Genesys are trademarks of their owners.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text("© \(Calendar.current.component(.year, from: Date())) scanjet200")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appIcon: NSImage {
        if let icon = NSApp.applicationIconImage, icon.size.width > 16 {
            return icon
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(size: NSSize(width: 96, height: 96))
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
        }
        .font(.callout)
    }
}
