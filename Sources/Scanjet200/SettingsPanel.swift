import SwiftUI
import ScanjetCore

struct SettingsPanel: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Form {
                        Picker("Kind:", selection: kindBinding) {
                            Text("Colour").tag(ScanKind.colour)
                            Text("Black & White").tag(ScanKind.blackAndWhite)
                            Text("Text").tag(ScanKind.text)
                            Text("Photo").tag(ScanKind.photo)
                        }
                        .tooltip("Colour, grayscale, high-contrast text, or Photo to split prints and negatives into files.")

                        Picker("Colours:", selection: $model.request.colorDepth) {
                            Text("Millions").tag(ColorDepth.millions)
                            Text("Billions").tag(ColorDepth.billions)
                        }
                        .tooltip("Millions is 8-bit colour. Billions is 16-bit, available for TIFF and PNG.")
                        .disabled(!model.request.format.supportsBillions || model.request.kind == .text)

                        Picker("Resolution:", selection: dpiBinding) {
                            ForEach(ScanMode.supportedOutputDPI, id: \.self) { dpi in
                                Text("\(dpi)").tag(dpi)
                            }
                        }
                        .tooltip("Output resolution in dpi. Higher values take longer and make larger files.")

                        Toggle("Use Custom Size", isOn: $model.request.useCustomSize)
                            .tooltip("Scan the rectangle drawn on the glass instead of a paper size.")

                        Picker("Size:", selection: $model.request.paperSize) {
                            Text("A4").tag(PaperSize.a4)
                            Text("US Letter").tag(PaperSize.usLetter)
                        }
                        .tooltip("Paper size when custom size is off.")
                        .disabled(model.request.useCustomSize)
                        .onChange(of: model.request.paperSize) { _ in
                            if !model.request.useCustomSize {
                                model.resetSelectionForPaper()
                            }
                        }

                        HStack(alignment: .center, spacing: 8) {
                            Text("Orientation:")
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            OrientationSegmentedControl(selection: $model.request.orientation)
                        }
                        .tooltip("How the page is rotated on the glass.")

                        HStack {
                            Text("Scan To:")
                            Spacer()
                            Button(model.request.outputDirectory.lastPathComponent) {
                                model.pickOutputFolder()
                            }
                            .lineLimit(1)
                            .tooltip("Choose the folder for scanned files.")
                        }

                        TextField("Name:", text: $model.request.name)
                            .tooltip(model.request.kind == .photo
                                     ? "File name without extension. Several photos become Name-1, Name-2, …"
                                     : "File name without extension. A number is added if the file already exists.")

                        Picker("Format:", selection: $model.request.format) {
                            ForEach(OutputFormat.allCases, id: \.self) { format in
                                Text(formatLabel(format)).tag(format)
                            }
                        }
                        .tooltip("File format. TIFF and PNG can save 16-bit colour; PDF and TIFF can combine pages.")
                        .onChange(of: model.request.format) { format in
                            if !format.supportsCombine {
                                model.request.combine = false
                            }
                        }

                        Toggle("Combine into single document", isOn: $model.request.combine)
                            .tooltip("Append this scan to an existing PDF or multi-page TIFF with the same name.")
                            .disabled(!model.combineEnabled)

                        Picker("Image Correction:", selection: $model.request.imageCorrection.mode) {
                            Text("None").tag(ImageCorrectionMode.none)
                            Text("Manual").tag(ImageCorrectionMode.manual)
                        }
                        .tooltip(model.request.kind == .photo
                                 ? "None keeps each photo as captured (after invert for film). Manual: drag the sliders — Save writes the same look into each file."
                                 : "None keeps the scan as captured. Manual: Overview, then drag the sliders — the glass updates live. Scan writes the same look.")
                    }
                    .formStyle(.grouped)
                    .padding(.top, 8)

                    if model.request.kind == .photo {
                        PhotoSettingsView()
                    }

                    if model.request.imageCorrection.mode == .manual {
                        ImageCorrectionManualView(
                            correction: Binding(
                                get: { model.request.imageCorrection },
                                set: { value in
                                    var request = model.request
                                    request.imageCorrection = value
                                    model.request = request
                                }
                            )
                        )
                            .padding(.horizontal, 24)
                            .padding(.top, -4)
                            .padding(.bottom, 12)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var kindBinding: Binding<ScanKind> {
        Binding(
            get: { model.request.kind },
            set: { model.setKind($0) }
        )
    }

    private var dpiBinding: Binding<Int> {
        Binding(
            get: { model.request.dpi },
            set: { model.setDPI($0) }
        )
    }

    private func formatLabel(_ format: OutputFormat) -> String {
        switch format {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .png: return "PNG"
        case .jpeg2000: return "JPEG 2000"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        }
    }
}
