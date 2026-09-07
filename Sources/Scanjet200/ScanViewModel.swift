import SwiftUI
import AppKit
import Darwin
import ScanjetCore

/// Forwards scan progress from a background thread to the main-actor view model
/// without capturing `self` in a `@Sendable` closure (Swift 6).
private final class ProgressSink: @unchecked Sendable {
    private weak var viewModel: ScanViewModel?

    init(viewModel: ScanViewModel) {
        self.viewModel = viewModel
    }

    var handler: ScanProgressHandler {
        { [weak viewModel] progress in
            let fraction = progress.fraction
            let band = progress.livePreview
            Task { @MainActor in
                viewModel?.progressFraction = fraction
                if let band {
                    viewModel?.applyLivePreview(band)
                }
            }
        }
    }
}

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var request = ScanRequest() {
        didSet { refreshDisplayPreview() }
    }
    @Published var showDetails = true
    @Published var scannerConnected = false
    @Published var isBusy = false
    @Published var progressFraction: Double = 0
    @Published var previewImage: NSImage? {
        didSet {
            sourcePreviewCG = nil
            refreshDisplayPreview()
        }
    }
    /// What the glass shows: Overview plus live Image Correction, or the raw live/scan frame.
    @Published private(set) var displayPreview: NSImage?
    @Published var livePreviewActive = false {
        didSet { refreshDisplayPreview() }
    }
    /// Scan live view sits in the selection box; Overview fills the whole bed.
    @Published var pinLivePreviewToSelection = false
    /// Overview is stored uncorrected so sliders can re-filter it on screen.
    @Published var previewIsOverview = false {
        didSet { refreshDisplayPreview() }
    }
    @Published var selection = ScanRegion.paper(.a4)
    @Published var lastError: String?
    @Published var lastErrorIsCancellation = false
    @Published var lastSavedPath: String?
    @Published var statusNotice: String?
    /// Hardware dpi values that have a shading file on this Mac.
    @Published var calibratedDPI: Set<Int> = []
    @Published var activeCalibrationDPI: Int?

    private var pollTimer: Timer?
    private var cancelToken: ScanCancel?
    private var statusTask: Task<Void, Never>?
    private var liveCanvas: NSBitmapImageRep?
    private var savedPreview: NSImage?
    private var savedPreviewWasOverview = false
    private var sourcePreviewCG: CGImage?
    private var liveFilledThroughY = 0
    private var didOfferCalibrationAssistant = false

    /// Re-filter the glass image as the sliders move — still Overview/Scan, or the live pass.
    func refreshDisplayPreview() {
        guard let previewImage else {
            displayPreview = nil
            return
        }
        guard request.imageCorrection.mode == .manual,
              request.imageCorrection.shouldApply else {
            displayPreview = previewImage
            return
        }

        if livePreviewActive {
            displayPreview = correctedLivePreview(from: previewImage)
            return
        }

        if sourcePreviewCG == nil {
            var rect = CGRect(origin: .zero, size: previewImage.size)
            sourcePreviewCG = previewImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let source = sourcePreviewCG else {
            displayPreview = previewImage
            return
        }
        let corrected = request.imageCorrection.applying(to: source)
        let image = NSImage(cgImage: corrected, size: NSSize(width: corrected.width, height: corrected.height))
        image.cacheMode = .never
        displayPreview = image
    }

    private func correctedLivePreview(from fallback: NSImage) -> NSImage {
        guard let canvas = liveCanvas, let src = canvas.bitmapData else { return fallback }
        let width = canvas.pixelsWide
        let height = canvas.pixelsHigh
        let bpr = canvas.bytesPerRow
        let filled = min(height, max(0, liveFilledThroughY))
        guard let copy = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: bpr, bitsPerPixel: 32
        ), let dest = copy.bitmapData else {
            return fallback
        }
        memcpy(dest, src, bpr * height)
        request.imageCorrection.applyToRGBA8(dest, width: width, rowCount: filled, bytesPerRow: bpr)
        guard let cg = copy.cgImage else { return fallback }
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        image.cacheMode = .never
        return image
    }

    init() {
        refreshScanner()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshScanner()
            }
        }
        resetSelectionForPaper()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func refreshScanner() {
        guard !isBusy else { return }
        scannerConnected = DeviceSession.isScannerAvailable()
        refreshCalibration()
    }

    func refreshCalibration() {
        calibratedDPI = Shading.installedDPI()
    }

    /// Once per launch, if this Mac has no shading files yet.
    func shouldOfferCalibrationAssistant() -> Bool {
        guard !didOfferCalibrationAssistant else { return false }
        didOfferCalibrationAssistant = true
        return calibratedDPI.isEmpty
    }

    /// Warning when the hardware pass for the current resolution has no profile.
    var calibrationWarning: String? {
        guard let hardware = try? ScanMode.choose(outputDPI: request.dpi).mode.dpi else {
            return nil
        }
        guard !calibratedDPI.contains(hardware) else { return nil }
        if calibratedDPI.isEmpty {
            return "No calibration on this Mac. Scans will show vertical bands until you capture a white-sheet reference."
        }
        return "No \(hardware) dpi calibration. Scans at this resolution will show vertical bands."
    }

    func resetSelectionForPaper() {
        selection = ScanRegion.paper(request.paperSize)
        request.region = selection
    }

    var combineEnabled: Bool {
        request.format.supportsCombine
    }

    func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = request.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            request.outputDirectory = url
        }
    }

    func overview() {
        runJob(kind: .overview)
    }

    func scan() {
        runJob(kind: .scan)
    }

    func calibrate(dpi: Int) {
        request.dpi = dpi
        runJob(kind: .calibrate(dpi))
    }

    func cancel() {
        guard isBusy else { return }
        cancelToken?.request()
    }

    private enum JobKind: Sendable {
        case overview, scan, calibrate(Int)
    }

    private struct JobOutcome: Sendable {
        var previewURL: URL?
        var savedPath: String?
        var notice: String?
    }

    private func runJob(kind: JobKind) {
        guard !isBusy else { return }
        lastError = nil
        lastErrorIsCancellation = false
        statusNotice = nil
        statusTask?.cancel()
        isBusy = true
        progressFraction = 0
        livePreviewActive = false
        savedPreview = previewImage
        savedPreviewWasOverview = previewIsOverview
        switch kind {
        case .scan:
            pinLivePreviewToSelection = true
            activeCalibrationDPI = nil
        case .overview:
            pinLivePreviewToSelection = false
            activeCalibrationDPI = nil
            previewIsOverview = true
        case .calibrate(let dpi):
            pinLivePreviewToSelection = false
            activeCalibrationDPI = dpi
        }
        liveCanvas = nil
        liveFilledThroughY = 0

        var jobRequest = request
        jobRequest.region = selection
        jobRequest.colorDepth = request.resolvedColorDepth

        let sink = ProgressSink(viewModel: self)
        let cancel = ScanCancel()
        cancelToken = cancel

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool {
                        let handler = sink.handler
                        switch kind {
                        case .overview:
                            let result = try ScanService.overview(request: jobRequest, progress: handler, cancel: cancel)
                            return JobOutcome(previewURL: result.previewURL, savedPath: nil, notice: nil)
                        case .scan:
                            let result = try ScanService.scan(request: jobRequest, progress: handler, cancel: cancel)
                            return JobOutcome(previewURL: result.previewURL,
                                              savedPath: result.outputURL.path,
                                              notice: Self.savedNotice(for: result.outputURL.path))
                        case .calibrate(let dpi):
                            let url = try ScanService.calibrate(dpi: dpi, progress: handler, cancel: cancel)
                            return JobOutcome(previewURL: nil, savedPath: url.path, notice: "Calibration saved")
                        }
                    }
                }.value

                applyOutcome(outcome, kind: kind)
            } catch ScanjetError.cancelled {
                lastErrorIsCancellation = true
                lastError = ScanjetError.cancelled.errorDescription
                restorePreviewAfterLive()
            } catch {
                lastError = error.localizedDescription
                restorePreviewAfterLive()
            }
            cancelToken = nil
            isBusy = false
            activeCalibrationDPI = nil
            ProcessMemory.releaseToOS()
            refreshScanner()
        }
    }

    func applyLivePreview(_ band: LivePreviewBand) {
        if liveCanvas == nil
            || liveCanvas?.pixelsWide != band.width
            || liveCanvas?.pixelsHigh != band.height {
            liveCanvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: band.width, pixelsHigh: band.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: band.width * 4, bitsPerPixel: 32
            )
            liveFilledThroughY = 0
        }
        guard let canvas = liveCanvas, let dest = canvas.bitmapData else { return }
        let destBPR = canvas.bytesPerRow
        let srcBPR = band.width * 4
        band.rgba.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<band.rows {
                memcpy(dest + (band.y + row) * destBPR, src + row * srcBPR, srcBPR)
            }
        }
        liveFilledThroughY = max(liveFilledThroughY, band.y + band.rows)
        if let cg = canvas.cgImage {
            let image = NSImage(cgImage: cg, size: NSSize(width: band.width, height: band.height))
            image.cacheMode = .never
            livePreviewActive = true
            previewImage = image
        }
    }

    private func restorePreviewAfterLive() {
        liveCanvas = nil
        liveFilledThroughY = 0
        previewIsOverview = savedPreviewWasOverview
        previewImage = savedPreview
        livePreviewActive = false
        savedPreview = nil
    }

    private func applyOutcome(_ outcome: JobOutcome, kind: JobKind) {
        let previous = savedPreview
        liveCanvas = nil
        liveFilledThroughY = 0
        savedPreview = nil
        switch kind {
        case .overview:
            previewIsOverview = true
        case .scan:
            previewIsOverview = false
        case .calibrate:
            break
        }
        if let path = outcome.savedPath {
            lastSavedPath = path
        }
        if let notice = outcome.notice {
            showNotice(notice)
        }
        if let url = outcome.previewURL,
           let data = try? Data(contentsOf: url),
           let image = NSImage(data: data) {
            image.cacheMode = .never
            previewImage = image
            try? FileManager.default.removeItem(at: url)
        } else {
            previewImage = previous
        }
        livePreviewActive = false
    }

    private func showNotice(_ text: String) {
        statusTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            statusNotice = text
        }
        statusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                statusNotice = nil
            }
        }
    }

    private nonisolated static func savedNotice(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        if folder.isEmpty {
            return "Saved \(name)"
        }
        return "Saved \(name) to \(folder)"
    }
}
