import SwiftUI
import AppKit

/// Holds the currently hovered help text so the window can draw a balloon
/// that is not clipped by Form / HStack.
final class TooltipBoard: ObservableObject {
    @Published var text: String?
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    @EnvironmentObject private var board: TooltipBoard

    func body(content: Content) -> some View {
        content.background(AppKitTooltip(text: text, board: board))
    }
}

fileprivate struct AppKitTooltip: NSViewRepresentable {
    let text: String
    let board: TooltipBoard

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, board: board)
    }

    func makeNSView(context: Context) -> TooltipNSView {
        let view = TooltipNSView()
        view.coordinator = context.coordinator
        view.tooltipText = text
        return view
    }

    func updateNSView(_ nsView: TooltipNSView, context: Context) {
        context.coordinator.text = text
        context.coordinator.board = board
        nsView.coordinator = context.coordinator
        nsView.tooltipText = text
    }

    final class Coordinator {
        var text: String
        var board: TooltipBoard
        var hoverGeneration = 0
        var inside = false

        init(text: String, board: TooltipBoard) {
            self.text = text
            self.board = board
        }

        func setInside(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            hoverGeneration += 1
            let generation = hoverGeneration
            if value {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.hoverGeneration == generation, self.inside else { return }
                    self.board.text = self.text
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.board.text == self.text else { return }
                    self.board.text = nil
                }
            }
        }
    }
}

/// Invisible view that attaches a tooltip and hover tracking to its SwiftUI superview.
fileprivate final class TooltipNSView: NSView {
    weak var coordinator: AppKitTooltip.Coordinator?
    private weak var trackedSuperview: NSView?
    private var trackingArea: NSTrackingArea?

    var tooltipText: String = "" {
        didSet { applyTooltip() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        autoresizingMask = [.width, .height]
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installTracking()
        applyTooltip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTracking()
        applyTooltip()
    }

    override func layout() {
        super.layout()
        installTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.setInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.setInside(false)
    }

    private func applyTooltip() {
        let value = tooltipText.isEmpty ? nil : tooltipText
        toolTip = value
        trackedSuperview?.toolTip = value
        superview?.toolTip = value
    }

    private func installTracking() {
        if let trackingArea, let trackedSuperview {
            trackedSuperview.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        trackedSuperview = superview
        guard let superview else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        superview.addTrackingArea(area)
        trackingArea = area
        applyTooltip()
    }

    deinit {
        if let trackingArea, let trackedSuperview {
            trackedSuperview.removeTrackingArea(trackingArea)
        }
    }
}

struct TooltipBalloon: View {
    @EnvironmentObject private var board: TooltipBoard
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        if let text = board.text ?? model.statusNotice {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .padding(.bottom, 8)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}
