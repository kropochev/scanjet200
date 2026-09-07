import SwiftUI
import AppKit
import ScanjetCore

struct GlassView: View {
    @Binding var selection: ScanRegion
    let previewImage: NSImage?
    let pinPreviewToSelection: Bool
    let paperSize: PaperSize
    let useCustomSize: Bool
    let connected: Bool

    @State private var dragOrigin: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let bed = bedRect(in: geo.size)
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
                    selectionOverlay(in: bed)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: bed), including: useCustomSize && connected ? .all : .none)
            .tooltip(connected
                  ? (useCustomSize
                     ? "Drag on the glass to choose the scan area."
                     : "Turn on Use Custom Size, then drag to choose the scan area.")
                  : "Connect the HP Scanjet 200 with a USB cable.")
            .onAppear { snapToPaperIfNeeded() }
            .onChange(of: paperSize) { _ in snapToPaperIfNeeded() }
            .onChange(of: useCustomSize) { _ in snapToPaperIfNeeded() }
        }
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

    private func bedRect(in size: CGSize) -> CGRect {
        let aspect = ScanBed.widthMM / ScanBed.heightMM
        var w = size.width * 0.88
        var h = w / aspect
        if h > size.height * 0.88 {
            h = size.height * 0.88
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func livePreview(_ image: NSImage, bed: CGRect) -> some View {
        let dest = mmToView(displayedRegion, bed: bed)
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
        let rect = mmToView(displayedRegion, bed: bed)
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
    }

    private func mmToView(_ region: ScanRegion, bed: CGRect) -> CGRect {
        let sx = bed.width / ScanBed.widthMM
        let sy = bed.height / ScanBed.heightMM
        return CGRect(x: bed.minX + region.xMM * sx,
                      y: bed.minY + region.yMM * sy,
                      width: region.widthMM * sx,
                      height: region.heightMM * sy)
    }

    private func viewToMM(_ point: CGPoint, bed: CGRect) -> (x: Double, y: Double) {
        let sx = ScanBed.widthMM / bed.width
        let sy = ScanBed.heightMM / bed.height
        return (Double(point.x - bed.minX) * sx, Double(point.y - bed.minY) * sy)
    }

    private func dragGesture(in bed: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard useCustomSize else { return }
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                }
                dragCurrent = value.location
                guard let a = dragOrigin, let b = dragCurrent else { return }
                let x0 = min(a.x, b.x)
                let y0 = min(a.y, b.y)
                let x1 = max(a.x, b.x)
                let y1 = max(a.y, b.y)
                let p0 = viewToMM(CGPoint(x: x0, y: y0), bed: bed)
                let p1 = viewToMM(CGPoint(x: x1, y: y1), bed: bed)
                selection = ScanRegion(
                    xMM: max(0, min(p0.x, ScanBed.widthMM)),
                    yMM: max(0, min(p0.y, ScanBed.heightMM)),
                    widthMM: max(10, min(ScanBed.widthMM, p1.x) - max(0, p0.x)),
                    heightMM: max(10, min(ScanBed.heightMM, p1.y) - max(0, p0.y))
                )
            }
            .onEnded { _ in
                dragOrigin = nil
                dragCurrent = nil
            }
    }
}
