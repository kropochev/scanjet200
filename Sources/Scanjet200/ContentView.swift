import SwiftUI
import ScanjetCore

struct ContentView: View {
    @EnvironmentObject private var model: ScanViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GlassView(selection: $model.selection,
                          photoFrames: $model.photoFrames,
                          selectedPhotoFrameID: $model.selectedPhotoFrameID,
                          previewImage: model.displayPreview,
                          pinPreviewToSelection: (model.isBusy && model.livePreviewActive
                            && model.pinLivePreviewToSelection)
                            || model.isPhotoReview,
                          paperSize: model.request.paperSize,
                          useCustomSize: model.request.useCustomSize,
                          connected: model.scannerConnected,
                          photoReview: model.isPhotoReview,
                          onPhotoFramesEdited: { model.markPhotoFramesEdited() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.showDetails {
                    SettingsPanel()
                        .frame(width: 320)
                }
            }

            if model.isBusy {
                ScanProgressBar(fraction: model.progressFraction)
            }

            if !model.isBusy, model.isPhotoReview {
                photoReviewBanner
            }

            if !model.isBusy, let warning = model.calibrationWarning {
                calibrationBanner(warning)
            }

            HStack(spacing: 12) {
                Button(model.showDetails ? "Hide Details" : "Show Details") {
                    model.showDetails.toggle()
                }
                .tooltip(model.showDetails
                      ? "Hide scan settings"
                      : "Show scan settings")
                Spacer()
                Button("Overview") {
                    model.overview()
                }
                .tooltip("Preview the glass at 75 dpi. Takes about 13 seconds.")
                .disabled(model.isBusy || !model.scannerConnected || model.isPhotoReview)
                if model.isBusy {
                    Button("Cancel") {
                        model.cancel()
                    }
                    .tooltip("Stop and return the carriage home. A partial file is not saved.")
                    .keyboardShortcut(.cancelAction)
                } else if model.isPhotoReview {
                    Button("Discard") {
                        model.discardPhotoSession()
                    }
                    .tooltip("Throw away this scan without saving photos.")
                    Button("Add") {
                        model.addPhotoFrame()
                    }
                    .tooltip("Add another crop rectangle on the glass.")
                    Button("Rotate") {
                        model.rotateSelectedPhotoFrame()
                    }
                    .tooltip("Rotate the selected photo 90° clockwise.")
                    .disabled(model.selectedPhotoFrameID == nil)
                    Button("Delete") {
                        model.deleteSelectedPhotoFrame()
                    }
                    .tooltip("Remove the selected photo frame.")
                    .disabled(model.selectedPhotoFrameID == nil)
                    Button(savePhotosTitle) {
                        model.savePhotos()
                    }
                    .tooltip("Crop each frame and write a file per photo.")
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.photoFrames.isEmpty)
                } else {
                    Button("Scan") {
                        model.scan()
                    }
                    .tooltip(model.request.kind == .photo
                             ? "Scan, then adjust photo frames on the glass before saving."
                             : "Scan the selected area with the current settings.")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.scannerConnected)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .zIndex(1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            TooltipBalloon()
                .padding(.bottom, tooltipBottomPadding)
                .allowsHitTesting(false)
        }
        .alert(model.lastErrorIsCancellation ? "Cancelled" : "Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil; model.lastErrorIsCancellation = false } }
        )) {
            Button("OK") {
                model.lastError = nil
                model.lastErrorIsCancellation = false
            }
        } message: {
            Text(model.lastError ?? "")
        }
        .onAppear {
            guard model.shouldOfferCalibrationAssistant() else { return }
            DispatchQueue.main.async {
                openWindow(id: "calibrate")
            }
        }
    }

    private var savePhotosTitle: String {
        let count = model.photoFrames.count
        if count <= 1 { return "Save photo" }
        return "Save \(count) photos"
    }

    private var tooltipBottomPadding: CGFloat {
        var extra: CGFloat = 48
        if !model.isBusy, model.calibrationWarning != nil { extra += 48 }
        if !model.isBusy, model.isPhotoReview { extra += 44 }
        return extra
    }

    private var photoReviewBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "crop")
                .foregroundStyle(.secondary)
            Text("Yellow boxes mark each photo. Drag them onto the film, then Save.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
    }

    private func calibrationBanner(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Calibrate…") {
                openWindow(id: "calibrate")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}

/// Linear bar without AppKit `NSProgressIndicator`, which can draw and hit-test
/// outside its SwiftUI frame and swallow clicks on Cancel.
private struct ScanProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}
