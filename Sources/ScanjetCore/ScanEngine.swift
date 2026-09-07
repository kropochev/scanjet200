import Foundation

public struct BootResult: Sendable {
    public var usbMode: String
    public var cold: Bool
    public var chipVersion: UInt8
    public var gpioA7: UInt8
    public var gpioA9: UInt8
}

public struct ScannedImage: Sendable {
    public var width: Int
    public var height: Int
    public var samplesPerPixel: Int
    public var mode: ScanMode
    public var outputDPI: Int
    public var rawURL: URL
    public var previewURL: URL?
}

/// Capture sequence from the HP Scanjet 200 Windows log (GL848+).
public final class ScanEngine: @unchecked Sendable {
    public let device: GenesysDevice
    private var progressHandler: ScanProgressHandler?
    private let cancel: ScanCancel?

    public init(device: GenesysDevice, progress: ScanProgressHandler? = nil, cancel: ScanCancel? = nil) {
        self.device = device
        self.progressHandler = progress ?? ScanLogger.handler
        self.cancel = cancel
    }

    private func report(_ phase: ScanProgress.Phase, _ fraction: Double = 0, _ message: String = "",
                        livePreview: LivePreviewBand? = nil) {
        progressHandler?(ScanProgress(phase: phase, fraction: fraction, message: message,
                                      livePreview: livePreview))
    }

    private func throwIfCancelled() throws {
        try cancel?.throwIfRequested()
    }

    @discardableResult
    public func coldBoot() throws -> BootResult {
        var usbMode = "unknown"
        if let speed = try? device.probeUSBSpeedByte() {
            usbMode = (speed & 0x08) != 0 ? "USB 1.1" : "USB 2.0"
        }

        // HP never writes 0x0E (ASIC reset) — do not reset the chip.
        let r06 = (try? device.readRegister(0x06)) ?? 0
        let cold = (r06 & 0x10) == 0
        let r00 = (try? device.readRegister(0x00)) ?? 0xff
        report(.preparing, 0, String(format: "before init: 0x00=0x%02x 0x06=0x%02x cold=%d", r00, r06, cold ? 1 : 0))

        try applyHPRegisters()
        try device.write0x8c(index: 0x10, value: 0x0b)
        try device.write0x8c(index: 0x13, value: 0x0b)
        try device.write0x8c(index: 0x17, data: [0x8b, 0x09])
        try loadHPTables()

        let chip = (try? device.readRegister(0x00)) ?? 0
        let gpioA7 = (try? device.readRegister(0xa7)) ?? 0
        let gpioA9 = (try? device.readRegister(0xa9)) ?? 0
        return BootResult(usbMode: usbMode, cold: cold, chipVersion: chip, gpioA7: gpioA7, gpioA9: gpioA9)
    }

    /// Capture a frame to a raw file and decode it into a TIFF.
    public func scan(options: ScanOptions) throws -> ScannedImage {
        try throwIfCancelled()
        let (mode, scale) = try ScanMode.choose(outputDPI: options.dpi)
        let color = options.mode == .color

        // LINCNT counts single-colour CIS lines, so it is a multiple of three;
        // RGB row count is also a multiple of scale so vertical averaging has no tail.
        // Y is cropped in software like X: capture from the top of the page through
        // the selection, then drop the rows above yMM. FEEDL is only the park-to-page offset.
        let skipRaw = max(0, Int((Double(mode.pageRows) * options.cropYMM / ScanBed.heightMM).rounded())) / scale * scale
        let wanted = Int((Double(mode.pageRows) * options.heightMM / ScanBed.heightMM).rounded())
        let rows = max(scale, min(mode.pageRows - skipRaw, wanted) / scale * scale)
        let captureRows = min(mode.pageRows, skipRaw + rows)
        let lineCount = UInt32(captureRows * 3)
        let totalBytes = captureRows * 3 * mode.bytesPerLine

        let seconds = mode.secondsPerPage * Double(captureRows) / Double(mode.pageRows)
        report(.capturing, 0, String(format: "pass %d dpi → %d dpi, %d×%d, %.1f MB raw, about %.0f s",
                                       mode.dpi, options.dpi, mode.samplesPerLine / scale, rows / scale,
                                       Double(totalBytes) / 1e6, seconds))

        let cropStart = max(0, Int((options.cropXMM / ScanBed.widthMM * Double(mode.samplesPerLine)).rounded()))
        let cropEnd = min(mode.samplesPerLine,
                          Int(((options.cropXMM + options.cropWidthMM) / ScanBed.widthMM
                               * Double(mode.samplesPerLine)).rounded()))
        let expectedOut = max(1, rows / scale)
        let shading = options.shading.flatMap { $0.width == mode.samplesPerLine ? $0 : nil }
        let live = LiveCISPreview(mode: mode, scale: scale, color: color, shading: shading,
                                  lut: ToneCurve.previewLUT(shading: shading, gamma: options.gamma),
                                  skipRaw: skipRaw, cropStart: cropStart, cropEnd: cropEnd,
                                  expectedOut: expectedOut)

        let rawURL = options.rawScratchURL
        try? FileManager.default.removeItem(at: rawURL)
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        guard let sink = FileHandle(forWritingAtPath: rawURL.path) else {
            throw ScanjetError.io("cannot create \(rawURL.path)")
        }
        sink.disableSystemCache()

        var keepRawScratch = false
        let parkDone = DispatchGroup()
        var parkLaunched = false
        func launchPark(inBackground: Bool) {
            guard !parkLaunched else { return }
            parkLaunched = true
            try? sink.close()
            let sendHome = { [self] in
                if cancel?.isRequested == true {
                    report(.homing, 0, "cancelled — returning home")
                }
                parkCarriage()
            }
            if inBackground {
                parkDone.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { parkDone.leave() }
                    sendHome()
                }
            } else {
                sendHome()
            }
        }
        func waitForPark() {
            if parkLaunched {
                parkDone.wait()
            } else {
                launchPark(inBackground: false)
            }
        }
        defer {
            waitForPark()
            if !keepRawScratch {
                try? FileManager.default.removeItem(at: rawURL)
            }
        }

        try ensureHome()
        try throwIfCancelled()
        try HPProgram.runInit(device, mode: mode, lineCount: lineCount, feedLines: options.feedLines)
        try throwIfCancelled()

        guard try waitForImageData(timeout: 15.0) else {
            throw ScanjetError.io("0x100 never reached 0x33 — CIS did not start writing DRAM")
        }
        _ = try? readValidWords()

        var received = 0
        var samples: [UInt16] = []
        let sampleStride = max(1, totalBytes / 2 / 100_000) * 2
        var lastReport = Date()
        let began = Date()

        while received < totalBytes {
            try throwIfCancelled()
            guard try waitForImageData(timeout: 15.0) else {
                report(.capturing, Double(received) / Double(max(totalBytes, 1)), "stream ended at \(received) bytes")
                break
            }
            let want = min(mode.chunkBytes, totalBytes - received)
            var chunkEmpty = false
            var liveBand: LivePreviewBand?
            do {
                try autoreleasepool {
                    try device.beginBulkRead(size: want)
                    let data = try readChunk(size: want)
                    if data.isEmpty {
                        report(.capturing, Double(received) / Double(max(totalBytes, 1)), "bulk: empty")
                        chunkEmpty = true
                        return
                    }
                    try sink.write(contentsOf: Data(data))
                    liveBand = live.ingest(data)
                    for i in stride(from: 0, to: data.count - 1, by: sampleStride) {
                        samples.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
                    }
                    received += data.count
                }
            } catch ScanjetError.cancelled {
                throw ScanjetError.cancelled
            } catch {
                report(.capturing, Double(received) / Double(max(totalBytes, 1)), "bulk: \(error)")
                break
            }
            if chunkEmpty {
                break
            }

            let done = Double(received) / Double(max(totalBytes, 1))
            let due = Date().timeIntervalSince(lastReport) > 2 || received >= totalBytes
            if let liveBand {
                var message = ""
                if due {
                    lastReport = Date()
                    message = String(format: "%.0f%%, about %.0f s left",
                                     done * 100,
                                     done > 0.01 ? Date().timeIntervalSince(began) * (1 - done) / done : seconds)
                }
                report(.capturing, done, message, livePreview: liveBand)
            } else if due {
                lastReport = Date()
                report(.capturing, done, String(format: "%.0f%%, about %.0f s left",
                                                done * 100,
                                                done > 0.01 ? Date().timeIntervalSince(began) * (1 - done) / done : seconds))
            }
        }
        if let band = live.flush() {
            report(.capturing, Double(received) / Double(max(totalBytes, 1)), "", livePreview: band)
        }

        // Carriage home only needs USB; decode only needs the raw file.
        launchPark(inBackground: true)
        try throwIfCancelled()

        guard received > mode.bytesPerLine * 3 else {
            throw ScanjetError.io("empty frame: received \(received) bytes")
        }

        if options.shading != nil && shading == nil {
            report(.decoding, 0, "calibration was taken at a different resolution — skipping")
        }
        let (black, white) = levels(samples, calibratedWhite: shading?.target)
        let tone = options.colorDepth == .billions
            ? (options.gamma.map { "16-bit gamma \($0)" } ?? "16-bit sRGB")
            : (options.gamma.map { "gamma \($0)" } ?? "sRGB")
        report(.decoding, 0, "levels: black \(black), white \(white), \(tone)")
        let curve = ToneCurve.make(black: black, white: white, gamma: options.gamma)
        let decoder = FrameDecoder(mode: mode, scale: scale, color: color, shading: shading,
                                   colorDepth: options.colorDepth, black: black, white: white,
                                   lut: curve.lut8, lut16: curve.lut16,
                                   cropStart: cropStart, cropEnd: cropEnd,
                                   skipRows: skipRaw / scale)
        report(.decoding, 0, "writing \(options.rasterEncoding.format.rawValue) (\(options.colorDepth == .billions ? "16" : "8")-bit)")
        let bps = options.colorDepth == .billions ? 16 : 8
        let spp = options.thresholdText ? 1 : decoder.samplesPerPixel
        var raster: PixelRowWriter
        if let clockwise = options.rotate90Clockwise {
            raster = try TransposeTIFFWriter(
                path: options.outputPath, srcWidth: decoder.outputWidth, srcHeight: expectedOut,
                samplesPerPixel: spp, bitsPerSample: bps, dpi: options.dpi, clockwise: clockwise
            )
        } else {
            raster = try RasterWriter.make(
                format: options.rasterEncoding.format, path: options.outputPath,
                width: decoder.outputWidth, height: expectedOut, samplesPerPixel: spp,
                bitsPerSample: bps, dpi: options.dpi, append: options.appendOutput
            )
        }
        if options.rotate90Clockwise == nil, !options.rasterEncoding.format.supportsBillions {
            raster = EightBitWriter(raster)
        }
        if options.thresholdText {
            raster = ThresholdWriter(raster, samplesPerPixel: decoder.samplesPerPixel)
        }
        if options.imageCorrection.shouldApply {
            raster = CorrectionWriter(raster, correction: options.imageCorrection,
                                      samplesPerPixel: decoder.samplesPerPixel)
        }
        let preview = options.makePreview
            ? PreviewSampler(sourceWidth: decoder.outputWidth, sourceHeight: expectedOut,
                             samplesPerPixel: decoder.samplesPerPixel)
            : nil
        if let preview {
            raster = PreviewTappingWriter(inner: raster, preview: preview)
        }
        let writer = raster
        var decodedRows = 0
        let height = try decoder.run(from: rawURL, to: writer, expectedRows: expectedOut) { fraction in
            decodedRows += 1
            if decodedRows % 16 == 0 {
                try self.throwIfCancelled()
            }
            self.report(.decoding, fraction)
        }
        try throwIfCancelled()
        try writer.finish()

        var previewURL: URL?
        if let image = preview?.makeImage() {
            previewURL = try ImageExporter.makePreviewPNG(from: image)
        }

        keepRawScratch = true
        return ScannedImage(width: decoder.outputWidth, height: height,
                            samplesPerPixel: decoder.samplesPerPixel,
                            mode: mode, outputDPI: options.dpi, rawURL: rawURL,
                            previewURL: previewURL)
    }

    /// USB bulk is synchronous; poll in 1 s slices so Cancel is not stuck behind a 30 s timeout.
    private func readChunk(size: Int) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(30)
        while true {
            try throwIfCancelled()
            let result = try device.bulkReadAllowingTimeout(length: size, timeoutMS: 1000)
            if !result.data.isEmpty {
                return result.data
            }
            if !result.timedOut {
                return []
            }
            if Date() >= deadline {
                throw ScanjetError.io("bulk timed out")
            }
        }
    }

    /// Scan status lives in the high bank: 0x100 (wValue 0x18E), not 0x00.
    /// hp2: 0xb2 — buffer empty, 0x36 — ramp, 0x33 — data flowing.
    private func waitForImageData(timeout: Double) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [UInt8] = []
        repeat {
            try throwIfCancelled()
            let status = (try? device.readRegister(0x100)) ?? 0
            if seen.last != status {
                seen.append(status)
            }
            if (status & 0x01) != 0 && (status & 0x80) == 0 {
                if seen.count > 1 {
                    report(.capturing, 0, "0x100: " + seen.map { String(format: "%02x", $0) }.joined(separator: "→"))
                }
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        report(.capturing, 0, "0x100 stuck at " + seen.map { String(format: "%02x", $0) }.joined(separator: "→"))
        return false
    }

    /// Valid-word counter: 4 bytes from 0x102 (same as GL124 in SANE).
    private func readValidWords() throws -> UInt32 {
        let data = try device.controlIn(request: 0x04, value: 0x18e, index: 0x0222, length: 4)
        guard data.count >= 3 else { return 0 }
        return (UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2])
    }

    /// CIS power. On this scanner the lamp only fires together with SCAN (see motor).
    func lampOnHP() throws {
        try device.writeRegister(0x0a, 0x40)
        try device.writeRegister(0xa6, 0x00)
        try device.writeRegister(0xa7, 0x50)
        try device.writeRegister(0xa8, 0x00)
        try device.writeRegister(0xa9, 0x50)
        try device.writeRegister(0x03, 0x9f)
        try device.writeRegister(0x08, 0x70)
        try device.writeRegister(0x0b, 0x2a)
    }

    /// Carriage motion only (no CIS optical dance).
    func startHPMotion(feedL: UInt32, lineCount: UInt32) throws {
        try loadHPTables()
        try lampOnHP()
        try device.writeRegister(0x21, 0x00)
        try device.writeRegister(0x22, 0x0f)
        try device.writeRegister(0x23, 0x00)
        try device.writeRegister(0x9d, 0x3f)
        try device.writeRegister(0x67, 0x00)
        try device.writeRegister(0x68, 0x01)
        try device.writeRegister(0x5f, 0xc0)
        try write24(0x3d, feedL)
        try write24(0x25, lineCount)
        try device.writeRegister(0x02, 0x38)
        Thread.sleep(forTimeInterval: 0.05)
        try device.writeRegister(0x02, 0x30)
        try device.writeRegister(0x0d, 0x01)
        try device.writeRegister(0x01, 0xc1)
        try device.writeRegister(0x0f, 0xff)
    }

    private func applyHPRegisters() throws {
        for (addr, value) in HPScanjet200.registers {
            try device.writeRegister(addr, value)
        }
    }

    private func loadHPTables() throws {
        try sendHPGamma()
        try sendHPSlopeWithGPIO()
    }

    /// Slope as in hp2: GPIO 0xA0/0x3C around each table, otherwise the CIS is not clocked.
    private func sendHPSlopeWithGPIO() throws {
        try device.writeRegister(0xa0, 0x08)
        try device.writeRegister(0x3c, 0x0a)
        try device.sendSlopeTable(number: 0, bytes: HPScanjet200.slopeTable)
        try device.writeRegister(0xa4, 0x00)
        try device.sendSlopeTable(number: 1, bytes: HPScanjet200.slopeTable)
        try device.writeRegister(0xaa, 0x00)
        try device.sendSlopeTable(number: 2, bytes: HPScanjet200.slopeTable)
        try device.writeRegister(0xac, 0x00)
        try device.writeRegister(0xa0, 0x00)
        try device.writeRegister(0x3c, 0xaa)
        try device.sendSlopeTable(number: 3, bytes: HPScanjet200.slopeTable)
        try device.writeRegister(0xae, 0x00)
        try device.sendSlopeTable(number: 4, bytes: HPScanjet200.slopeTable)
        try device.writeRegister(0xb0, 0x00)
    }

    private func sendHPGamma() throws {
        // Second HP gamma: 16-bit LE 0,1,2,... — linear.
        var table = [UInt8](repeating: 0, count: 512)
        for i in 0..<256 {
            table[i * 2] = UInt8(i & 0xff)
            table[i * 2 + 1] = 0
        }
        for channel in 0..<3 {
            try device.writeAHB(address: 0x0100_0000 + 0x200 * UInt32(channel), data: table)
        }
        try device.writeRegister(0xbd, 0x00)
        try device.writeRegister(0xbe, 0x07)
    }

    private func write24(_ address: UInt16, _ value: UInt32) throws {
        try device.writeRegister(address, UInt8((value >> 16) & 0xff))
        try device.writeRegister(address + 1, UInt8((value >> 8) & 0xff))
        try device.writeRegister(address + 2, UInt8(value & 0xff))
    }

    /// Without calibration stretch by percentiles; with it, white is already
    /// the reference and must not be stretched or a blank sheet becomes noise.
    ///
    /// Black is a fixed fraction of white: the sensor dark floor is about 10%
    /// (raw minimum on a densely printed page — 4556 with white at 43425).
    /// Adapting it to the frame would crush midtones on a light original.
    private func levels(_ samples: [UInt16], calibratedWhite: UInt16?) -> (UInt16, UInt16) {
        var sample = samples
        guard !sample.isEmpty else { return (0, 65535) }
        sample.sort()
        guard let white = calibratedWhite else {
            return (sample[sample.count * 2 / 100], sample[sample.count * 98 / 100])
        }
        let floor = UInt16(UInt32(white) / 10)
        return (min(sample[sample.count / 200], floor), white)
    }

    /// Finish as HP does: drop SCAN and return the carriage home.
    /// Without this the next scan starts wherever the carriage stopped.
    private func stopScan() throws {
        parkCarriage()
    }

    /// In 0x101 bit 0x08 is the home sensor, bit 0x01 is the motor running.
    /// Wait for both: right after the command the motor has not started yet,
    /// and "motor stopped" would accept the carriage where it already stood.
    @discardableResult
    public static func waitForHome(_ device: GenesysDevice, timeout: Double, trace: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [UInt8] = []
        while Date() < deadline {
            guard let status = try? device.readRegister(0x101) else { return false }
            if trace && seen.last != status {
                seen.append(status)
            }
            if (status & 0x08) != 0 && (status & 0x01) == 0 {
                if trace && seen.count > 1 {
                    ScanLogger.log(.homing, 0, "0x101: " + seen.map { String(format: "%02x", $0) }.joined(separator: "→"))
                }
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if trace {
            ScanLogger.log(.homing, 0, "0x101 stuck: " + seen.map { String(format: "%02x", $0) }.joined(separator: "→"))
        }
        return false
    }

    private func parkCarriage() {
        for _ in 0..<2 {
            _ = try? device.writeRegister(0x0a, 0x40)
            _ = try? device.writeRegister(0x01, 0xc0)
        }
        if !ScanEngine.waitForHome(device, timeout: 60) {
            report(.homing, 0, "carriage did not return home — the next scan may be offset")
        }
    }

    /// Recovery if a previous run died and left the carriage in the field.
    /// The chip has no separate "go home" command: the pass itself returns,
    /// so a stuck carriage is pulled back with a short dummy scan.
    public func ensureHome() throws {
        try throwIfCancelled()
        guard let status = try? device.readRegister(0x101), status != 0 else { return }
        if (status & 0x08) != 0 && (status & 0x01) == 0 { return }
        if (status & 0x01) != 0 {
            _ = ScanEngine.waitForHome(device, timeout: 60)
            try throwIfCancelled()
            return
        }
        report(.preparing, 0, String(format: "carriage stuck (0x101=%02x) — dummy pass", status))
        let quick = ScanMode.all[0]
        try? HPProgram.runInit(device, mode: quick, lineCount: 120,
                               feedLines: quick.feedLines, verbose: false)
        do {
            _ = try waitForImageData(timeout: 10)
        } catch ScanjetError.cancelled {
            try? stopScan()
            throw ScanjetError.cancelled
        }
        try? stopScan()
        try throwIfCancelled()
    }
}
