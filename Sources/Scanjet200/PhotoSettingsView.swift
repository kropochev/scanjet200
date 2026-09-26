import SwiftUI
import ScanjetCore

struct PhotoSettingsView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Subject:", selection: subjectBinding) {
                Text("Colour print").tag(PhotoSubject.colourPrint)
                Text("Black & White print").tag(PhotoSubject.blackAndWhitePrint)
                Text("Colour negative").tag(PhotoSubject.colourNegative)
                Text("Black & White negative").tag(PhotoSubject.blackAndWhiteNegative)
            }
            .fixedSize()
            .tooltip("Prints are photographs on paper. Negatives are inverted to a positive after the scan.")

            Picker("Layout:", selection: layoutBinding) {
                Text("Prints").tag(PhotoLayout.prints)
                Text("Film strip").tag(PhotoLayout.filmStrip)
            }
            .fixedSize()
            .tooltip("Prints saves the chosen region as one photo. Film strip splits a negative or slide strip into frames.")

            if model.request.photo.layout.isFilm {
                Picker("Film:", selection: filmFormatBinding) {
                    Text("Auto").tag(PhotoFilmFormat.auto)
                    Text("35 mm (24×36)").tag(PhotoFilmFormat.mm35)
                    Text("35 mm half-frame (18×24)").tag(PhotoFilmFormat.mm35Half)
                    Text("120 — 6×4.5").tag(PhotoFilmFormat.mm120_6x45)
                    Text("120 — 6×6").tag(PhotoFilmFormat.mm120_6x6)
                    Text("120 — 6×9").tag(PhotoFilmFormat.mm120_6x9)
                    Text("16 mm").tag(PhotoFilmFormat.mm16)
                    Text("110").tag(PhotoFilmFormat.mm110)
                    Text("127 (4×4)").tag(PhotoFilmFormat.mm127)
                }
                .fixedSize()
                .tooltip("GOST / DIN / ASA is film speed, not size. Soviet 35 mm from Chaika or Agat is often half-frame; Lubitel is 120 6×6. Auto guesses from the strip width.")

                if model.request.photo.filmFormat == .auto,
                   let guessed = model.photoSession?.detectedFilmFormat {
                    Text("Guessed: \(filmFormatLabel(guessed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Crop margin:", selection: $model.request.photo.cropMarginMM) {
                Text("0 mm").tag(0)
                Text("1 mm").tag(1)
                Text("2 mm").tag(2)
            }
            .fixedSize()
            .tooltip("How much to trim inside each frame when saving.")

            if model.request.photo.subject.isNegative {
                Toggle("Invert to positive", isOn: $model.request.photo.invertToPositive)
                    .tooltip("Turn the negative into a positive. Reflective scans without a lightbox are limited.")
                Toggle("Auto levels", isOn: $model.request.photo.autoLevels)
                    .tooltip("Stretch contrast after invert. Needed for a dark reflective film scan.")
                if model.request.photo.subject == .colourNegative {
                    Toggle("Orange mask", isOn: $model.request.photo.orangeMask)
                        .tooltip("Compensate the orange film base on colour negatives.")
                }
            }

            if model.request.photo.layout.isFilm, model.photoSession != nil {
                Stepper(value: stripCountBinding, in: 1...24) {
                    Text("Frames: \(model.photoSession?.frames.count ?? 1)")
                }
                .tooltip("Re-slice the strip into this many frames.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, -4)
        .padding(.bottom, 12)
    }

    private var subjectBinding: Binding<PhotoSubject> {
        Binding(
            get: { model.request.photo.subject },
            set: { model.setPhotoSubject($0) }
        )
    }

    private var layoutBinding: Binding<PhotoLayout> {
        Binding(
            get: { model.request.photo.layout },
            set: { model.setPhotoLayout($0) }
        )
    }

    private var filmFormatBinding: Binding<PhotoFilmFormat> {
        Binding(
            get: { model.request.photo.filmFormat },
            set: { model.setPhotoFilmFormat($0) }
        )
    }

    private var stripCountBinding: Binding<Int> {
        Binding(
            get: { model.photoSession?.frames.count ?? 1 },
            set: { model.reslicePhotoStrip(count: $0) }
        )
    }

    private func filmFormatLabel(_ format: PhotoFilmFormat) -> String {
        switch format {
        case .auto: return "Auto"
        case .mm35: return "35 mm (24×36)"
        case .mm35Half: return "35 mm half-frame (18×24)"
        case .mm120_6x45: return "120 — 6×4.5"
        case .mm120_6x6: return "120 — 6×6"
        case .mm120_6x9: return "120 — 6×9"
        case .mm16: return "16 mm"
        case .mm110: return "110"
        case .mm127: return "127 (4×4)"
        }
    }
}
