import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
import ScanjetCore

enum TestSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var hardwareRequired: Bool {
        ProcessInfo.processInfo.environment["SCANJET_HARDWARE"] == "1"
    }

    static func makeTempDir(_ name: String = "scanjet-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func expectedPixelSize(
        dpi: Int,
        paper: PaperSize = .a4,
        heightMM: Double? = nil,
        orientation: ScanOrientation = .deg0
    ) throws -> (width: Int, height: Int) {
        let (mode, scale) = try ScanMode.choose(outputDPI: dpi)
        let paperRegion = ScanRegion.paper(paper)
        let region = ScanRegion(
            xMM: paperRegion.xMM,
            yMM: paperRegion.yMM,
            widthMM: paperRegion.widthMM,
            heightMM: heightMM ?? paperRegion.heightMM
        )

        let skipRaw = max(0, Int((Double(mode.pageRows) * region.yMM / ScanBed.heightMM).rounded())) / scale * scale
        let wanted = Int((Double(mode.pageRows) * region.heightMM / ScanBed.heightMM).rounded())
        let rows = max(scale, min(mode.pageRows - skipRaw, wanted) / scale * scale)
        var height = rows / scale

        let cropStart = max(0, Int((region.xMM / ScanBed.widthMM * Double(mode.samplesPerLine)).rounded()))
        let cropEnd = min(mode.samplesPerLine,
                          Int(((region.xMM + region.widthMM) / ScanBed.widthMM
                               * Double(mode.samplesPerLine)).rounded()))
        var width = max(1, (cropEnd - cropStart) / scale)

        if orientation == .deg90 || orientation == .deg270 {
            swap(&width, &height)
        }
        return (width, height)
    }

    static func writeRGBTIFF(to url: URL, width: Int, height: Int, bitsPerComponent: Int = 8) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = .noneSkipLast
        var bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue)
        if bitsPerComponent == 16 {
            bitmapInfo.insert(.byteOrder16Little)
        }
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            throw NSError(domain: "ScanjetTests", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create test bitmap"])
        }
        for y in 0..<height {
            let t = CGFloat(y) / CGFloat(max(height - 1, 1))
            ctx.setFillColor(CGColor(red: t, green: 0.2, blue: 1 - t, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "ScanjetTests", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "cannot render test bitmap"])
        }
        try writeImage(image, to: url, type: .tiff)
    }

    static func writeGrayTIFF(to url: URL, width: Int, height: Int, values: [UInt8]) throws {
        precondition(values.count == width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = values
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else {
            throw NSError(domain: "ScanjetTests", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create gray test bitmap"])
        }
        try writeImage(image, to: url, type: .tiff)
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ScanjetTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ScanjetTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
        }
    }

    struct RasterInfo {
        var width: Int
        var height: Int
        var bitsPerComponent: Int
        var samplesPerPixel: Int
        var isMonochrome: Bool
        var uti: String
        var pageCount: Int
    }

    static func inspectRaster(_ url: URL) throws -> RasterInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "ScanjetTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        let count = CGImageSourceGetCount(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ScanjetTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "empty image \(url.path)"])
        }
        let uti = (CGImageSourceGetType(source) as String?) ?? ""
        let spp = image.colorSpace?.numberOfComponents ?? 0
        return RasterInfo(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            samplesPerPixel: spp,
            isMonochrome: image.colorSpace?.model == .monochrome,
            uti: uti,
            pageCount: count
        )
    }

    static func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width
        let h = image.height
        var out = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return out
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }

    static func rgbPixels(_ image: CGImage) -> [(UInt8, UInt8, UInt8)] {
        let w = image.width
        let h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels = [(UInt8, UInt8, UInt8)]()
        pixels.reserveCapacity(w * h)
        for i in stride(from: 0, to: out.count, by: 4) {
            pixels.append((out[i], out[i + 1], out[i + 2]))
        }
        return pixels
    }

    static func pdfPageCount(_ url: URL) throws -> Int {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: "ScanjetTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open PDF \(url.path)"])
        }
        return doc.pageCount
    }

    static func pdfPageSize(_ url: URL) throws -> CGSize {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw NSError(domain: "ScanjetTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "empty PDF \(url.path)"])
        }
        return page.bounds(for: .mediaBox).size
    }

    struct CLIResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func scanjetBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SCANJET_BIN"] {
            let url = URL(fileURLWithPath: override)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                          "SCANJET_BIN is not executable: \(override)")
            return url
        }

        let root = repoRoot
        let candidates = [
            root.appendingPathComponent(".build/debug/scanjet"),
            root.appendingPathComponent(".build/release/scanjet")
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return existing
        }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build", "--product", "scanjet"]
        build.currentDirectoryURL = root
        try build.run()
        build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0, "swift build --product scanjet failed")

        guard let built = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "ScanjetTests", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "scanjet binary not found after build"])
        }
        return built
    }

    static func runCLI(_ args: [String],
                       cwd: URL? = nil,
                       timeout: TimeInterval = 30) throws -> CLIResult {
        let binary = try scanjetBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd ?? repoRoot

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            XCTFail("scanjet \(args.joined(separator: " ")) timed out after \(timeout)s")
        }
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func usageMessage(_ error: Error) -> String {
        if let scanjet = error as? ScanjetError {
            return scanjet.description
        }
        return String(describing: error)
    }
}

func XCTAssertUsage(_ error: Error, contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    let message = TestSupport.usageMessage(error)
    XCTAssertTrue(message.localizedCaseInsensitiveContains(needle),
                  "expected usage error containing “\(needle)”, got: \(message)",
                  file: file, line: line)
}
