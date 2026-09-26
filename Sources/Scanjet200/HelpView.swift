import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("Scanner") {
                    Text("This app drives an HP Scanjet 200 over USB (03f0:1c05). HP did not ship a driver for modern macOS.")
                    Text("Plug the scanner in before launching the app. Close the official Image Capture or another copy of this app — USB access is exclusive.")
                    Text("On first use macOS may ask for USB permission.")
                }

                section("Calibrate") {
                    Text("CIS segments differ in brightness and colour. Calibrate once per resolution with a clean, unmarked white A4 sheet on the glass.")
                    Text("If this Mac has no profiles yet, a Calibration Assistant opens and a banner warns that scans will show vertical bands. Scanjet 200 → Calibrate also has the assistant and 300 / 600 / 1200 / 2400 dpi.")
                    Text("300 dpi also covers 75, 100, and 150 dpi; 600 dpi also covers 200 dpi. Use a flat, unmarked sheet — creases bake into the profile.")
                    Text("References are stored in ~/Library/Application Support/scanjet/ and belong to this scanner. Calibrate is disabled when the scanner is unplugged.")
                }

                section("Overview and Scan") {
                    Text("Overview is a 75 dpi preview of the whole bed and takes about 13 seconds.")
                    Text("Turn on Use Custom Size and drag on the glass to choose the region. Size (A4 / US Letter) is used when custom size is off.")
                    Text("Orientation rotates the saved file to match how the page sits on the glass.")
                    Text("Scan writes to the folder in Scan To, using Name and Format. If the file exists, a number is appended unless Combine is on.")
                    Text("In Photo with Prints, Scan saves the chosen region as one photo. With Film strip, Scan does not write files yet. Yellow boxes mark each frame: drag them onto the film, add or delete boxes, then Save. Discard throws the scan away.")
                    Text("Cancel stops the pass and returns the carriage home. A partial file is not saved.")
                }

                section("Colour and format") {
                    Text("Kind: Colour, Black & White, Text (high-contrast), or Photo.")
                    Text("Photo finds a film strip on the glass after Scan. Choose the film size (35 mm, half-frame 18×24, 120, 16 mm, 110, 127) or Auto. GOST / DIN / ASA on the box is speed, not the frame size — Soviet Chaika and Agat are often 35 mm half-frame; Lubitel is 120 6×6.")
                    Text("Colour and black-and-white prints sit face-down; choose the region on the glass to crop to the print. A film strip is inverted to a positive and split into frames.")
                    Text("The Scanjet 200 has no backlight. Negatives are inverted from a reflective scan — readable, not archival. A lightbox on top of the film helps a lot.")
                    Text("Millions is 8-bit. Billions is 16-bit and only for TIFF and PNG. JPEG, HEIC, GIF, BMP, and PDF stay 8-bit.")
                    Text("Image Correction: None leaves the scan as captured. Manual adjusts brightness, tint, temperature, and saturation on the glass after Overview. Restore Defaults centres the sliders. Scan writes the same look into the file. In Photo, correction is applied to each frame when you save, after invert.")
                    Text("Combine appends pages into one PDF or multi-page TIFF when the file already exists. It is not used in Photo.")
                }

                section("Command line") {
                    Text("The packaged app also contains the scanjet CLI. From Terminal:")
                    Text("\"/path/to/Scanjet 200.app/Contents/MacOS/scanjet\" list")
                        .font(.system(.body, design: .monospaced))
                    Text("scanjet scan, calibrate, and list use the same engine as this window. Overview, Custom Size, live preview, and Cancel stay in the app.")
                }

                section("Resolution and time") {
                    row("75, 100, 150, 300 dpi", "about 13 s for A4")
                    row("200, 600 dpi", "about 47 s")
                    row("1200 dpi", "about 3 min")
                    row("2400 dpi", "about 12 min, files of 1 GB and more")
                }

                Text("Unofficial project, not affiliated with HP. scanjet200 is MIT; bundled libusb is LGPL-2.1-or-later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scanjet 200")
                .font(.title)
                .bold()
            Text("Help")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(left)
            Spacer(minLength: 12)
            Text(right)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }
}
