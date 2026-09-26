import SwiftUI
import ScanjetCore

struct PhotoFrameEditor: View {
    @Binding var frames: [PhotoFrame]
    @Binding var selectedID: UUID?
    let bed: CGRect
    let capture: ScanRegion
    var onEdited: () -> Void

    @State private var dragOrigin: CGPoint?
    @State private var dragHandle: Handle?
    @State private var startRegion: ScanRegion?

    private enum Handle {
        case create
        case move
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        ZStack {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                frameOverlay(frame, index: index)
            }
        }
        .contentShape(Rectangle())
        .gesture(canvasGesture)
    }

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOrigin == nil {
                    beginDrag(at: value.startLocation)
                }
                updateDrag(to: value.location)
            }
            .onEnded { _ in
                dragOrigin = nil
                dragHandle = nil
                startRegion = nil
            }
    }

    private func frameOverlay(_ frame: PhotoFrame, index: Int) -> some View {
        let rect = GlassGeometry.mmToView(frame.region, bed: bed)
        let selected = frame.id == selectedID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1)
                .stroke(selected ? Color.yellow : Color.white, lineWidth: selected ? 2.5 : 1.5)
                .background(Color.yellow.opacity(selected ? 0.08 : 0.03))
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65))
                .foregroundStyle(.white)
                .offset(x: 4, y: 4)
            if selected {
                handle(.topLeft, in: rect)
                handle(.topRight, in: rect)
                handle(.bottomLeft, in: rect)
                handle(.bottomRight, in: rect)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .onTapGesture {
            selectedID = frame.id
        }
    }

    private func handle(_ kind: Handle, in rect: CGRect) -> some View {
        let point: CGPoint = {
            switch kind {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .topRight: return CGPoint(x: rect.width, y: 0)
            case .bottomLeft: return CGPoint(x: 0, y: rect.height)
            case .bottomRight: return CGPoint(x: rect.width, y: rect.height)
            default: return .zero
            }
        }()
        return Circle()
            .fill(Color.yellow)
            .frame(width: 8, height: 8)
            .position(x: point.x, y: point.y)
    }

    private func beginDrag(at point: CGPoint) {
        dragOrigin = point
        if let selected = frames.first(where: { $0.id == selectedID }) {
            let rect = GlassGeometry.mmToView(selected.region, bed: bed)
            if let corner = hitHandle(point, rect: rect) {
                dragHandle = corner
                startRegion = selected.region
                return
            }
            if rect.insetBy(dx: -6, dy: -6).contains(point) {
                dragHandle = .move
                startRegion = selected.region
                selectedID = selected.id
                return
            }
        }
        if let hit = frames.enumerated().reversed().first(where: {
            GlassGeometry.mmToView($0.element.region, bed: bed).insetBy(dx: -4, dy: -4).contains(point)
        }) {
            selectedID = hit.element.id
            dragHandle = .move
            startRegion = hit.element.region
            return
        }
        dragHandle = .create
        selectedID = nil
    }

    private func hitHandle(_ point: CGPoint, rect: CGRect) -> Handle? {
        let handles: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        for (kind, corner) in handles {
            if hypot(point.x - corner.x, point.y - corner.y) < 12 {
                return kind
            }
        }
        return nil
    }

    private func updateDrag(to point: CGPoint) {
        guard let origin = dragOrigin, let handle = dragHandle else { return }
        switch handle {
        case .create:
            let x0 = min(origin.x, point.x)
            let y0 = min(origin.y, point.y)
            let x1 = max(origin.x, point.x)
            let y1 = max(origin.y, point.y)
            let region = GlassGeometry.region(
                fromView: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), bed: bed
            ).clamped(to: capture)
            if let index = frames.firstIndex(where: { $0.id == selectedID }) {
                frames[index].region = region
            } else {
                let frame = PhotoFrame(region: region)
                frames.append(frame)
                selectedID = frame.id
            }
            onEdited()
        case .move:
            guard let start = startRegion, let id = selectedID,
                  let index = frames.firstIndex(where: { $0.id == id }) else { return }
            let a = GlassGeometry.viewToMM(origin, bed: bed)
            let b = GlassGeometry.viewToMM(point, bed: bed)
            var region = start
            region.xMM += b.x - a.x
            region.yMM += b.y - a.y
            frames[index].region = region.clamped(to: capture)
            onEdited()
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            guard let start = startRegion, let id = selectedID,
                  let index = frames.firstIndex(where: { $0.id == id }) else { return }
            let startView = GlassGeometry.mmToView(start, bed: bed)
            var x0 = startView.minX
            var y0 = startView.minY
            var x1 = startView.maxX
            var y1 = startView.maxY
            switch handle {
            case .topLeft: x0 = point.x; y0 = point.y
            case .topRight: x1 = point.x; y0 = point.y
            case .bottomLeft: x0 = point.x; y1 = point.y
            case .bottomRight: x1 = point.x; y1 = point.y
            default: break
            }
            let region = GlassGeometry.region(
                fromView: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)),
                bed: bed
            ).clamped(to: capture)
            frames[index].region = region
            onEdited()
        }
    }
}
