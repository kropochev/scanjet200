import SwiftUI
import AppKit
import ScanjetCore

struct GlassView: View {
    @Binding var selection: ScanRegion
    @Binding var photoFrames: [PhotoFrame]
    @Binding var selectedPhotoFrameID: UUID?
    let previewImage: NSImage?
    let pinPreviewToSelection: Bool
    let paperSize: PaperSize
    let useCustomSize: Bool
    let connected: Bool
    let photoReview: Bool
    var onPhotoFramesEdited: () -> Void = {}

    @State private var dragOrigin: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let bed = GlassGeometry.bedRect(in: geo.size)
            ZStack {
                Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))

                if !connected {
                    Text("Connect the HP Scanjet 200")
                        .foregroundStyle(.secondary)
                } else {
                    bedOutline(in: bed)
                    if let previewImage {
                        if pinPreviewToSelection {
                            livePreview(previewImage, bed: bed)
                        } else {
                            Image(nsImage: previewImage)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: bed.width, height: bed.height)
                                .clipped()
                                .id(ObjectIdentifier(previewImage))
                        }
                    }
                    if photoReview {
                        PhotoFrameEditor(
                            frames: $photoFrames,
                            selectedID: $selectedPhotoFrameID,
                            bed: bed,
                            capture: displayedRegion,
                            onEdited: onPhotoFramesEdited
                        )
                    } else {
                        selectionOverlay(in: bed)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: bed), including: useCustomSize && connected && !photoReview ? .all : .none)
            .tooltip(tooltipText)
            .onAppear { snapToPaperIfNeeded() }
            .onChange(of: paperSize) { _ in snapToPaperIfNeeded() }
            .onChange(of: useCustomSize) { _ in snapToPaperIfNeeded() }
        }
    }

    private var tooltipText: String {
        if !connected {
            return "Connect the HP Scanjet 200 with a USB cable."
        }
        if photoReview {
            return "Drag to add a frame. Drag a frame to move it, or a corner to resize."
        }
        if useCustomSize {
            return "Drag on the glass to choose the scan area."
        }
        return "Turn on Use Custom Size, then drag to choose the scan area."
    }

    private var displayedRegion: ScanRegion {
        useCustomSize ? selection : ScanRegion.paper(paperSize)
    }

    private func snapToPaperIfNeeded() {
        guard !useCustomSize else { return }
        let paper = ScanRegion.paper(paperSize)
        if selection != paper {
            selection = paper
        }
    }

    private func livePreview(_ image: NSImage, bed: CGRect) -> some View {
        let dest = GlassGeometry.mmToView(displayedRegion, bed: bed)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.low)
            .frame(width: dest.width, height: dest.height)
            .clipped()
            .position(x: dest.midX, y: dest.midY)
    }

    private func bedOutline(in bed: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            .foregroundStyle(Color.white.opacity(0.25))
            .frame(width: bed.width, height: bed.height)
            .position(x: bed.midX, y: bed.midY)
    }

    private func selectionOverlay(in bed: CGRect) -> some View {
        let rect = GlassGeometry.mmToView(displayedRegion, bed: bed)
        return ZStack {
            RoundedRectangle(cornerRadius: 1)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 5], dashPhase: 5))
                .foregroundStyle(Color.black)
            RoundedRectangle(cornerRadius: 1)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                .foregroundStyle(Color.white)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private func dragGesture(in bed: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard useCustomSize, !photoReview else { return }
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                }
                dragCurrent = value.location
                guard let a = dragOrigin, let b = dragCurrent else { return }
                let x0 = min(a.x, b.x)
                let y0 = min(a.y, b.y)
                let x1 = max(a.x, b.x)
                let y1 = max(a.y, b.y)
                selection = GlassGeometry.region(
                    fromView: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), bed: bed
                )
            }
            .onEnded { _ in
                dragOrigin = nil
                dragCurrent = nil
            }
    }
}
