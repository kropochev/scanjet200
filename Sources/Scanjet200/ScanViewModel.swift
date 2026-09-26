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
    @Published var photoSession: PhotoReviewSession?
    @Published var photoFrames: [PhotoFrame] = []
    @Published var selectedPhotoFrameID: UUID?

    private var pollTimer: Timer?
    private var cancelToken: ScanCancel?
    private var statusTask: Task<Void, Never>?
    private var liveCanvas: NSBitmapImageRep?
    private var savedPreview: NSImage?
    private var savedPreviewWasOverview = false
    private var sourcePreviewCG: CGImage?
    private var liveFilledThroughY = 0
    private var didOfferCalibrationAssistant = false
    private var photoDPIFollowsSubject = true
    private var applyingPhotoDefaults = false
    private var photoTempURLs: [URL] = []

    /// Re-filter the glass image as the sliders move — still Overview/Scan, or the live pass.
    func refreshDisplayPreview() {
        guard let previewImage else {
            displayPreview = nil
            return
        }
        let photoAdjust = photoSession != nil
            && !livePreviewActive
            && (request.photo.effectiveInvert
                || request.photo.effectiveOrangeMask
                || request.photo.effectiveAutoLevels)
        let correct = request.imageCorrection.mode == .manual && request.imageCorrection.shouldApply
        guard photoAdjust || correct else {
            displayPreview = previewImage
            return
        }

        if livePreviewActive, correct, !photoAdjust {
            displayPreview = correctedLivePreview(from: previewImage)
            return
        }

        if sourcePreviewCG == nil {
            var rect = CGRect(origin: .zero, size: previewImage.size)
            sourcePreviewCG = previewImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard var current = sourcePreviewCG else {
            displayPreview = previewImage
            return
        }
        if photoAdjust {
            current = NegativeConvert.applying(current, settings: request.photo)
        }
        if correct {
            current = request.imageCorrection.applying(to: current)
        }
        let image = NSImage(cgImage: current, size: NSSize(width: current.width, height: current.height))
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
        for url in photoTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
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
        request.kind != .photo && request.format.supportsCombine
    }

    var isPhotoReview: Bool {
        photoSession != nil
    }

    func setKind(_ kind: ScanKind) {
        let old = request.kind
        if kind != .photo {
            discardPhotoSession()
        }
        request.kind = kind
        if kind == .photo, old != .photo {
            applyPhotoKindDefaults()
        }
    }

    func setDPI(_ dpi: Int) {
        request.dpi = dpi
        if request.kind == .photo, !applyingPhotoDefaults {
            photoDPIFollowsSubject = false
        }
    }

    func setPhotoSubject(_ subject: PhotoSubject) {
        request.photo.subject = subject
        if photoDPIFollowsSubject {
            applyingPhotoDefaults = true
            request.dpi = subject.defaultDPI
            applyingPhotoDefaults = false
        }
    }

    func setPhotoLayout(_ layout: PhotoLayout) {
        request.photo.layout = layout
    }

    func setPhotoFilmFormat(_ format: PhotoFilmFormat) {
        request.photo.filmFormat = format
        guard request.photo.layout.isFilm, photoSession != nil else { return }
        let bounds = photoSession?.stripBounds
            ?? ScanRegion.union(photoFrames.map(\.region))
            ?? photoSession?.region
        guard let bounds else { return }
        reslicePhotoStrip(
            count: PhotoDetector.estimatedFrameCount(strip: bounds, format: format)
        )
    }

    func applyPhotoKindDefaults() {
        applyingPhotoDefaults = true
        request.format = .jpeg
        request.combine = false
        request.dpi = request.photo.subject.defaultDPI
        photoDPIFollowsSubject = true
        applyingPhotoDefaults = false
    }

    func markPhotoFramesEdited() {
        guard var session = photoSession else { return }
        session.frames = photoFrames
        session.framesWereEdited = true
        photoSession = session
    }

    func reslicePhotoStrip(count: Int) {
        guard var session = photoSession else { return }
        let bounds = session.stripBounds
            ?? ScanRegion.union(photoFrames.map(\.region))
            ?? session.region
        session.stripBounds = bounds
        session.frames = PhotoDetector.splitStrip(bounds: bounds, count: count)
        session.framesWereEdited = true
        session.detectedFilmFormat = request.photo.filmFormat.resolved(for: bounds)
        photoSession = session
        photoFrames = session.frames
        selectedPhotoFrameID = session.frames.first?.id
    }

    func addPhotoFrame() {
        let capture = photoSession?.region ?? selection
        let frame = PhotoFrame(region: ScanRegion(
            xMM: capture.xMM + capture.widthMM * 0.25,
            yMM: capture.yMM + capture.heightMM * 0.25,
            widthMM: max(20, capture.widthMM * 0.5),
            heightMM: max(20, capture.heightMM * 0.5)
        ))
        photoFrames.append(frame)
        selectedPhotoFrameID = frame.id
        markPhotoFramesEdited()
    }

    func rotateSelectedPhotoFrame() {
        guard let id = selectedPhotoFrameID,
              let index = photoFrames.firstIndex(where: { $0.id == id }) else { return }
        photoFrames[index] = photoFrames[index].rotating90Clockwise()
        markPhotoFramesEdited()
    }

    func deleteSelectedPhotoFrame() {
        guard let id = selectedPhotoFrameID else { return }
        photoFrames.removeAll { $0.id == id }
        selectedPhotoFrameID = photoFrames.first?.id
        markPhotoFramesEdited()
    }

    func discardPhotoSession() {
        photoSession?.removeTemporaryFiles()
        photoSession = nil
        photoFrames = []
        selectedPhotoFrameID = nil
        photoTempURLs = []
        pinLivePreviewToSelection = false
        refreshDisplayPreview()
    }

    func savePhotos() {
        guard var session = photoSession, !isBusy else { return }
        session.frames = photoFrames
        runJob(kind: .savePhotos(session))
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
        case overview, scan, calibrate(Int), savePhotos(PhotoReviewSession)
    }

    private struct JobOutcome: Sendable {
        var previewURL: URL? = nil
        var savedPath: String? = nil
        var notice: String? = nil
        var photoSession: PhotoReviewSession? = nil
        var keepPinToSelection = false
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
            if photoSession != nil {
                discardPhotoSession()
                pinLivePreviewToSelection = true
            }
        case .overview:
            pinLivePreviewToSelection = false
            activeCalibrationDPI = nil
            previewIsOverview = true
            if photoSession != nil {
                discardPhotoSession()
            }
        case .calibrate(let dpi):
            pinLivePreviewToSelection = false
            activeCalibrationDPI = dpi
        case .savePhotos:
            pinLivePreviewToSelection = true
            activeCalibrationDPI = nil
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
                            if jobRequest.kind == .photo, !jobRequest.photo.layout.isFilm {
                                let result = try ScanService.scan(request: jobRequest, progress: handler, cancel: cancel)
                                return JobOutcome(previewURL: result.previewURL,
                                                  savedPath: result.outputURL.path,
                                                  notice: Self.savedPhotosNotice(urls: result.outputURLs))
                            }
                            if jobRequest.kind == .photo {
                                let session = try ScanService.capturePhoto(
                                    request: jobRequest, progress: handler, cancel: cancel
                                )
                                return JobOutcome(
                                    previewURL: session.previewURL,
                                    notice: "Yellow boxes mark each photo. Drag them onto the film, then Save.",
                                    photoSession: session,
                                    keepPinToSelection: true
                                )
                            }
                            let result = try ScanService.scan(request: jobRequest, progress: handler, cancel: cancel)
                            return JobOutcome(previewURL: result.previewURL,
                                              savedPath: result.outputURL.path,
                                              notice: Self.savedNotice(for: result.outputURL.path))
                        case .calibrate(let dpi):
                            let url = try ScanService.calibrate(dpi: dpi, progress: handler, cancel: cancel)
                            return JobOutcome(previewURL: nil, savedPath: url.path, notice: "Calibration saved")
                        case .savePhotos(let session):
                            let result = try ScanService.savePhotoSession(session, request: jobRequest)
                            let notice = Self.savedPhotosNotice(urls: result.outputURLs)
                            return JobOutcome(
                                previewURL: result.previewURL,
                                savedPath: result.outputURL.path,
                                notice: notice
                            )
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
        case .savePhotos:
            previewIsOverview = false
            photoSession = nil
            photoFrames = []
            selectedPhotoFrameID = nil
            photoTempURLs = []
            pinLivePreviewToSelection = false
        }
        if let session = outcome.photoSession {
            photoSession = session
            photoFrames = session.frames
            selectedPhotoFrameID = session.frames.first?.id
            photoTempURLs = [session.captureURL]
            if let preview = session.previewURL {
                photoTempURLs.append(preview)
            }
            pinLivePreviewToSelection = true
        }
        if outcome.keepPinToSelection {
            pinLivePreviewToSelection = true
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

    private nonisolated static func savedPhotosNotice(urls: [URL]) -> String {
        guard let first = urls.first else { return "Saved photos" }
        let folder = first.deletingLastPathComponent().lastPathComponent
        if urls.count == 1 {
            return savedNotice(for: first.path)
        }
        if folder.isEmpty {
            return "Saved \(urls.count) photos"
        }
        return "Saved \(urls.count) photos to \(folder)"
    }
}
