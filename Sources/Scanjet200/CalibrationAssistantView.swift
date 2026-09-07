import SwiftUI
import ScanjetCore

struct CalibrationAssistantView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("Why") {
                    Text("The CIS sensor is built from segments that differ in brightness and colour by about 8%. Without a per-column white reference, scans show vertical bands and a colour cast.")
                    Text("A profile belongs to this scanner and this Mac. Copying the app to another computer, or plugging in a different unit, means capturing a new reference.")
                }

                section("What you need") {
                    Text("A clean, unmarked, flat white A4 sheet. Coloured or cream paper will push later scans toward blue. Creases, dust, and writing become stripes in every scan.")
                    Text("Lay the sheet on the glass so it covers the full width, then close the lid.")
                }

                section("What happens") {
                    Text("Each optical pass has its own sensor width, so each resolution you use needs its own file. 300 dpi also covers 75, 100, and 150 dpi; 600 dpi also covers 200 dpi.")
                    Text("Profiles are stored in ~/Library/Application Support/scanjet/. You can skip resolutions you never scan at.")
                }

                resolutions

                if !model.scannerConnected {
                    Text("Connect the HP Scanjet 200 to run a calibration pass.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.isBusy {
                    Text("Calibration is running — watch the main window. Keep the lid closed until it finishes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear { model.refreshCalibration() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calibration Assistant")
                .font(.title)
                .bold()
            Text(model.calibratedDPI.isEmpty
                 ? "One-time setup for this scanner"
                 : "White-sheet references on this Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var resolutions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolutions")
                .font(.headline)
            ForEach(ScanMode.all, id: \.dpi) { mode in
                resolutionRow(mode)
            }
        }
    }

    private func resolutionRow(_ mode: ScanMode) -> some View {
        let done = model.calibratedDPI.contains(mode.dpi)
        let running = model.activeCalibrationDPI == mode.dpi
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mode.dpi) dpi")
                    .font(.body.weight(.medium))
                Text(subtitle(for: mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(running ? "Working…" : (done ? "Recalibrate" : "Calibrate")) {
                model.calibrate(dpi: mode.dpi)
            }
            .disabled(model.isBusy || !model.scannerConnected)
            .help("Scan a blank white sheet at \(mode.dpi) dpi to flatten lamp and sensor variation.")
        }
        .padding(.vertical, 6)
    }

    private func subtitle(for mode: ScanMode) -> String {
        let covered = mode.coveredOutputDPI.filter { $0 != mode.dpi }
        let coverage = covered.isEmpty
            ? "this resolution only"
            : "also \(covered.map { "\($0)" }.joined(separator: ", ")) dpi"
        return "\(coverage) · \(durationLabel(mode.secondsPerPage))"
    }

    private func durationLabel(_ seconds: Double) -> String {
        if seconds >= 90 {
            return "about \(Int((seconds / 60).rounded())) min"
        }
        return "about \(Int(seconds.rounded())) s"
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
