import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ScanjetCore

final class PhotoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PhotoDetector.usesVision = false
    }

    override func tearDown() {
        PhotoDetector.usesVision = true
        super.tearDown()
    }

    func testPhotoCLIDefaults() throws {
        let request = try ScanRequest.parseCLI(["--kind", "photo"])
        XCTAssertEqual(request.kind, .photo)
        XCTAssertEqual(request.format, .jpeg)
        XCTAssertEqual(request.dpi, 600)
        XCTAssertEqual(request.photo.subject, .colourPrint)
        XCTAssertEqual(request.photo.layout, .prints)
        XCTAssertFalse(request.combine)
        XCTAssertTrue(request.capturesColour)
    }

    func testPhotoNegativeCLIDefaultsDPI() throws {
        let request = try ScanRequest.parseCLI([
            "--kind", "photo",
            "--photo-subject", "colour-negative",
            "--photo-layout", "strip"
        ])
        XCTAssertEqual(request.photo.subject, .colourNegative)
        XCTAssertEqual(request.photo.layout, .filmStrip)
        XCTAssertEqual(request.dpi, 1200)
        XCTAssertTrue(request.capturesColour)
        XCTAssertFalse(try ScanRequest.parseCLI([
            "--kind", "photo", "--photo-subject", "bw-print"
        ]).capturesColour)
    }

    func testPhotoCLIKeepsExplicitDPIAndFormat() throws {
        let request = try ScanRequest.parseCLI([
            "--kind", "photo", "--dpi", "300", "--format", "png"
        ])
        XCTAssertEqual(request.dpi, 300)
        XCTAssertEqual(request.format, .png)
    }

    func testPhotoRejectsCombine() {
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--kind", "photo", "--combine", "--format", "tiff"])) {
            XCTAssertUsage($0, contains: "combine")
        }
        XCTAssertThrowsError(try ScanKind.parseCLI("sepia")) { XCTAssertUsage($0, contains: "kind") }
    }

    func testPhotoOutputNames() throws {
        let dir = try TestSupport.makeTempDir("scanjet-photo-names")
        defer { try? FileManager.default.removeItem(at: dir) }
        var request = ScanRequest(kind: .photo, name: "Photo", format: .jpeg)
        request.kind = .photo
        request.outputDirectory = dir

        XCTAssertEqual(request.photoOutputURLs(count: 1).map(\.lastPathComponent), ["Photo.jpg"])
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("Photo.jpg").path, contents: Data()
        )
        XCTAssertEqual(request.photoOutputURLs(count: 1).map(\.lastPathComponent), ["Photo-2.jpg"])
        XCTAssertEqual(
            request.photoOutputURLs(count: 3).map(\.lastPathComponent),
            ["Photo-1.jpg", "Photo-2.jpg", "Photo-3.jpg"]
        )
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("Photo-1.jpg").path, contents: Data()
        )
        XCTAssertEqual(
            request.photoOutputURLs(count: 2).map(\.lastPathComponent),
            ["Photo-2.jpg", "Photo-3.jpg"]
        )
    }

    func testSplitStripAndSortOrder() {
        let strip = ScanRegion(xMM: 10, yMM: 20, widthMM: 152, heightMM: 24)
        XCTAssertEqual(PhotoDetector.estimatedFrameCount(stripLengthMM: 152), 4)
        XCTAssertEqual(PhotoDetector.estimatedFrameCount(stripLengthMM: 152, format: .mm35Half), 8)
        let frames = PhotoDetector.splitStrip(bounds: strip, count: 4)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].region.xMM, 10, accuracy: 0.01)
        XCTAssertEqual(frames[1].region.xMM, 10 + 38, accuracy: 0.01)
        XCTAssertEqual(frames[3].region.xMM + frames[3].region.widthMM, 162, accuracy: 0.01)
        XCTAssertTrue(frames[0].region.yMM <= frames[3].region.yMM)

        let vertical = PhotoDetector.splitStrip(
            bounds: ScanRegion(xMM: 5, yMM: 10, widthMM: 24, heightMM: 76), count: 2
        )
        XCTAssertEqual(vertical.count, 2)
        XCTAssertLessThan(vertical[0].region.yMM, vertical[1].region.yMM)
    }

    func testInfersFilmFormatFromStripWidth() {
        let half = ScanRegion(xMM: 0, yMM: 0, widthMM: 133, heightMM: 35)
        XCTAssertEqual(PhotoFilmFormat.inferred(from: half), .mm35Half)

        let full = ScanRegion(xMM: 0, yMM: 0, widthMM: 160, heightMM: 35)
        XCTAssertEqual(PhotoFilmFormat.inferred(from: full), .mm35)

        let medium = ScanRegion(xMM: 0, yMM: 0, widthMM: 186, heightMM: 61)
        XCTAssertEqual(PhotoFilmFormat.inferred(from: medium), .mm120_6x6)
    }

    func testPhotoFormatCLI() throws {
        let request = try ScanRequest.parseCLI([
            "--kind", "photo",
            "--photo-layout", "strip",
            "--photo-format", "half-frame"
        ])
        XCTAssertEqual(request.photo.layout, .filmStrip)
        XCTAssertEqual(request.photo.filmFormat, .mm35Half)
        XCTAssertEqual(try PhotoFilmFormat.parseCLI("6x6"), .mm120_6x6)
        XCTAssertEqual(try PhotoFilmFormat.parseCLI("18x24"), .mm35Half)
    }

    func testPrintsKeepWholeRegionWithoutDetection() throws {
        let capture = ScanRegion.fullBed
        let image = try makeFixture(width: 436, height: 594) { x, y, width, height in
            let mmX = Double(x) / Double(width) * capture.widthMM
            let mmY = Double(y) / Double(height) * capture.heightMM
            if mmX >= 20 && mmX < 100 && mmY >= 20 && mmY < 120 {
                return (70, 70, 70)
            }
            if mmX >= 110 && mmX < 180 && mmY >= 150 && mmY < 240 {
                return (90, 90, 90)
            }
            return (245, 245, 245)
        }
        let result = PhotoDetector.detect(
            image: image, capture: capture,
            settings: PhotoSettings(subject: .colourPrint, layout: .prints)
        )
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames.first?.region, capture)
        XCTAssertNil(result.stripBounds)
    }

    func testDetectsAndSplitsFilmStrip() throws {
        let capture = ScanRegion.fullBed
        let image = try makeFixture(width: 436, height: 594) { x, y, width, height in
            let mmX = Double(x) / Double(width) * capture.widthMM
            let mmY = Double(y) / Double(height) * capture.heightMM
            if mmX >= 20 && mmX < 180 && mmY >= 40 && mmY < 72 {
                return (200, 110, 40)
            }
            return (245, 245, 245)
        }
        let result = PhotoDetector.detect(
            image: image, capture: capture,
            settings: PhotoSettings(subject: .colourNegative, layout: .filmStrip)
        )
        XCTAssertEqual(result.frames.count, 4)
        XCTAssertEqual(result.filmFormat, .mm35)
        XCTAssertNotNil(result.stripBounds)
        XCTAssertEqual(result.stripBounds?.widthMM ?? 0, 160, accuracy: 16)
    }

    func testFilmStripAtTopOfA4SplitsAlongTheRibbon() throws {
        let capture = ScanRegion.fullBed
        let image = try makeFixture(width: 436, height: 594) { x, y, width, height in
            let mmX = Double(x) / Double(width) * capture.widthMM
            let mmY = Double(y) / Double(height) * capture.heightMM
            if mmX >= 10 && mmX < 190 && mmY >= 2 && mmY < 36 {
                return (50, 50, 50)
            }
            return (245, 245, 245)
        }
        let result = PhotoDetector.detect(
            image: image, capture: capture,
            settings: PhotoSettings(
                subject: .blackAndWhiteNegative, layout: .filmStrip, filmFormat: .mm35Half
            )
        )
        XCTAssertNotNil(result.stripBounds)
        XCTAssertEqual(result.stripBounds?.heightMM ?? 0, 35, accuracy: 12)
        XCTAssertEqual(result.stripBounds?.yMM ?? 0, 2, accuracy: 12)
        XCTAssertGreaterThan(result.stripBounds?.widthMM ?? 0, result.stripBounds?.heightMM ?? 0)
        XCTAssertGreaterThanOrEqual(result.frames.count, 6)
        XCTAssertLessThanOrEqual(result.frames.count, 12)
        XCTAssertEqual(result.filmFormat, .mm35Half)
        for frame in result.frames {
            XCTAssertLessThan(frame.region.heightMM, 50)
            XCTAssertEqual(frame.region.yMM, 2, accuracy: 14)
        }
        XCTAssertLessThan(result.frames[0].region.xMM, result.frames[1].region.xMM)
    }

    func testFilmStripDetectionFindsLightRibbonOnDarkLid() throws {
        let capture = ScanRegion.fullBed
        let image = try makeFixture(width: 436, height: 594) { x, y, width, height in
            let mmX = Double(x) / Double(width) * capture.widthMM
            let mmY = Double(y) / Double(height) * capture.heightMM
            if mmX >= 10 && mmX < 190 && mmY >= 2 && mmY < 36 {
                return (220, 220, 210)
            }
            return (18, 18, 18)
        }
        let result = PhotoDetector.detect(
            image: image, capture: capture,
            settings: PhotoSettings(
                subject: .blackAndWhiteNegative, layout: .filmStrip, filmFormat: .mm35Half
            )
        )
        XCTAssertEqual(result.stripBounds?.heightMM ?? 0, 35, accuracy: 14)
        XCTAssertGreaterThan(result.stripBounds?.widthMM ?? 0, 120)
        XCTAssertLessThan(result.frames[0].region.heightMM, 55)
    }

    func testNegativeInvertRaisesMeanLuminance() throws {
        let dark = try makeFixture(width: 64, height: 48) { _, _, _, _ in (40, 22, 8) }
        let settings = PhotoSettings(
            subject: .colourNegative, invertToPositive: true, autoLevels: true, orangeMask: false
        )
        let converted = NegativeConvert.applying(dark, settings: settings)
        XCTAssertGreaterThan(NegativeConvert.meanLuminance(converted), NegativeConvert.meanLuminance(dark) + 40)
    }

    func testExportWritesSeparateFilesAndCrops() throws {
        let dir = try TestSupport.makeTempDir("scanjet-photo-export")
        defer { try? FileManager.default.removeItem(at: dir) }

        let capture = ScanRegion.fullBed
        let image = try makeFixture(width: 218, height: 297) { x, y, width, height in
            let mmX = Double(x) / Double(width) * capture.widthMM
            let mmY = Double(y) / Double(height) * capture.heightMM
            if mmX >= 10 && mmX < 70 && mmY >= 10 && mmY < 80 {
                return (220, 20, 20)
            }
            if mmX >= 90 && mmX < 150 && mmY >= 120 && mmY < 190 {
                return (20, 20, 220)
            }
            return (240, 240, 240)
        }
        let source = dir.appendingPathComponent("capture.tiff")
        try TestSupport.writeImage(image, to: source, type: .tiff)

        var request = ScanRequest(kind: .photo, name: "Shot", format: .png)
        request.kind = .photo
        request.format = .png
        request.name = "Shot"
        request.outputDirectory = dir
        request.photo.straighten = false
        request.orientation = .deg0

        let frames = [
            PhotoFrame(region: ScanRegion(xMM: 10, yMM: 10, widthMM: 60, heightMM: 70)),
            PhotoFrame(region: ScanRegion(xMM: 90, yMM: 120, widthMM: 60, heightMM: 70))
        ]
        let urls = try PhotoExport.save(
            captureURL: source, frames: frames, capture: capture, request: request
        )
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Shot-1.png", "Shot-2.png"])

        let first = try TestSupport.inspectRaster(urls[0])
        let second = try TestSupport.inspectRaster(urls[1])
        XCTAssertTrue(abs(first.width - 60) <= 2)
        XCTAssertTrue(abs(first.height - 70) <= 2)
        XCTAssertTrue(abs(second.width - 60) <= 2)
        XCTAssertTrue(abs(second.height - 70) <= 2)

        guard let firstImage = load(urls[0]), let secondImage = load(urls[1]) else {
            XCTFail("could not reload crops")
            return
        }
        XCTAssertGreaterThan(meanChannel(TestSupport.rgbPixels(firstImage), 0),
                             meanChannel(TestSupport.rgbPixels(firstImage), 2))
        XCTAssertGreaterThan(meanChannel(TestSupport.rgbPixels(secondImage), 2),
                             meanChannel(TestSupport.rgbPixels(secondImage), 0))
    }

    func testToScanOptionsUsesPhotoColour() throws {
        var colour = ScanRequest(kind: .photo)
        colour.kind = .photo
        colour.photo.subject = .colourPrint
        XCTAssertEqual(try colour.toScanOptions(outputPath: "/tmp/a.tiff").mode, .color)

        colour.photo.subject = .blackAndWhiteNegative
        XCTAssertEqual(try colour.toScanOptions(outputPath: "/tmp/a.tiff").mode, .gray)
    }

    private func meanChannel(_ pixels: [(UInt8, UInt8, UInt8)], _ channel: Int) -> Int {
        guard !pixels.isEmpty else { return 0 }
        var sum = 0
        for pixel in pixels {
            switch channel {
            case 0: sum += Int(pixel.0)
            case 1: sum += Int(pixel.1)
            default: sum += Int(pixel.2)
            }
        }
        return sum / pixels.count
    }

    private func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func makeFixture(
        width: Int,
        height: Int,
        pixel: (Int, Int, Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else {
            throw NSError(domain: "ScanjetTests", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "cannot make photo fixture"])
        }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y, width, height)
                let o = (y * width + x) * 4
                ptr[o] = r
                ptr[o + 1] = g
                ptr[o + 2] = b
                ptr[o + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "ScanjetTests", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "cannot make photo fixture"])
        }
        return image
    }
}
