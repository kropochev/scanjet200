import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ScanjetCore

final class ImageExportTests: XCTestCase {
    func testExportFormatsPreserveColourDimensions() throws {
        let dir = try TestSupport.makeTempDir("scanjet-export")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cases: [(OutputFormat, String)] = [
            (.jpeg, "public.jpeg"),
            (.png, "public.png"),
            (.tiff, "public.tiff"),
            (.gif, "com.compuserve.gif"),
            (.bmp, "com.microsoft.bmp"),
            (.jpeg2000, "public.jpeg-2000")
        ]

        for (format, uti) in cases {
            var request = ScanRequest(format: format)
            request.dpi = 75
            let source = dir.appendingPathComponent("source-\(format.rawValue).tiff")
            try TestSupport.writeRGBTIFF(to: source, width: 40, height: 24)
            let output = dir.appendingPathComponent("out.\(format.fileExtension)")
            try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), format.rawValue)
            let info = try TestSupport.inspectRaster(output)
            XCTAssertEqual(info.width, 40, format.rawValue)
            XCTAssertEqual(info.height, 24, format.rawValue)
            XCTAssertEqual(info.uti, uti, format.rawValue)
            XCTAssertFalse(info.isMonochrome, format.rawValue)
            if format == .jpeg2000 {
                let bytes = try Data(contentsOf: output)
                XCTAssertFalse(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                               "JPEG 2000 must not silently fall back to PNG")
            }
        }
    }

    func testHEICExport() throws {
        let dir = try TestSupport.makeTempDir("scanjet-heic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 32, height: 16)
        let request = ScanRequest(format: .heic)
        let output = dir.appendingPathComponent("out.heic")
        do {
            try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)
        } catch {
            throw XCTSkip("HEIC export unavailable: \(error)")
        }
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 32)
        XCTAssertEqual(info.height, 16)
        XCTAssertTrue(info.uti.contains("heic") || info.uti.contains("heif"))
    }

    func testOrientationAndGrayscaleAndText() throws {
        let dir = try TestSupport.makeTempDir("scanjet-post")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 40, height: 20)

        let rotated = ScanRequest(kind: .colour, orientation: .deg90, format: .png)
        let rotatedURL = dir.appendingPathComponent("rot.png")
        try ImageExporter.export(sourceTIFF: source, request: rotated, outputURL: rotatedURL)
        let rot = try TestSupport.inspectRaster(rotatedURL)
        XCTAssertEqual(rot.width, 20)
        XCTAssertEqual(rot.height, 40)

        let gray = ScanRequest(kind: .blackAndWhite, format: .png)
        let grayURL = dir.appendingPathComponent("gray.png")
        try ImageExporter.export(sourceTIFF: source, request: gray, outputURL: grayURL)
        XCTAssertTrue(try TestSupport.inspectRaster(grayURL).isMonochrome)
    }

    func testTextThresholdIsBinary() throws {
        let dir = try TestSupport.makeTempDir("scanjet-text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeGrayTIFF(to: source, width: 4, height: 1, values: [0, 179, 180, 255])

        let request = ScanRequest(kind: .text, format: .png)
        let output = dir.appendingPathComponent("text.png")
        try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)

        guard let image = CGImageSourceCreateWithURL(output as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("cannot read threshold PNG")
        }
        let gray = TestSupport.grayPixels(image)
        XCTAssertEqual(gray, [0, 0, 255, 255])
    }

    func testCombinePDFAndTIFF() throws {
        let dir = try TestSupport.makeTempDir("scanjet-combine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 16, height: 12)

        let pdf = ScanRequest(format: .pdf, combine: true)
        let pdfURL = dir.appendingPathComponent("doc.pdf")
        try ImageExporter.export(sourceTIFF: source, request: pdf, outputURL: pdfURL)
        try ImageExporter.export(sourceTIFF: source, request: pdf, outputURL: pdfURL)
        XCTAssertEqual(try TestSupport.pdfPageCount(pdfURL), 2)

        let tiff = ScanRequest(format: .tiff, combine: true)
        let tiffURL = dir.appendingPathComponent("doc.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 16, height: 12)
        try ImageExporter.export(sourceTIFF: source, request: tiff, outputURL: tiffURL)
        try TestSupport.writeRGBTIFF(to: source, width: 16, height: 12)
        try ImageExporter.export(sourceTIFF: source, request: tiff, outputURL: tiffURL)
        XCTAssertEqual(try TestSupport.inspectRaster(tiffURL).pageCount, 2)
    }

    func testColourTIFFPassthroughKeepsSixteenBit() throws {
        let dir = try TestSupport.makeTempDir("scanjet-tiff-pass")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 32, height: 16, bitsPerComponent: 16)
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int
        var request = ScanRequest(format: .tiff)
        request.colorDepth = .billions
        let output = dir.appendingPathComponent("out.tiff")
        try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int, size)
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 32)
        XCTAssertEqual(info.height, 16)
        XCTAssertEqual(info.bitsPerComponent, 16)
    }

    func testStreamingPreviewFromWriterTIFF() throws {
        let dir = try TestSupport.makeTempDir("scanjet-stream-preview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 800, samplesPerPixel: 3, dpi: 75, bitsPerSample: 8)
        for y in 0..<400 {
            let row = [UInt8](repeating: UInt8(y % 256), count: 800 * 3)
            try writer.write(row: row)
        }
        try writer.finish()
        let preview = try ImageExporter.makePreviewPNG(from: source, maxDimension: 100)
        defer { try? FileManager.default.removeItem(at: preview) }
        let info = try TestSupport.inspectRaster(preview)
        XCTAssertEqual(info.width, 100)
        XCTAssertEqual(info.height, 50)
        XCTAssertEqual(info.uti, "public.png")
    }

    func testStreamingPNGFromWriterTIFF() throws {
        let dir = try TestSupport.makeTempDir("scanjet-stream-png")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 40, samplesPerPixel: 3, dpi: 75, bitsPerSample: 8)
        for _ in 0..<24 {
            var row = [UInt8](repeating: 0, count: 40 * 3)
            for x in 0..<40 {
                row[x * 3] = 200
                row[x * 3 + 1] = 40
                row[x * 3 + 2] = 10
            }
            try writer.write(row: row)
        }
        try writer.finish()
        let output = dir.appendingPathComponent("out.png")
        try ImageExporter.export(sourceTIFF: source, request: ScanRequest(format: .png), outputURL: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 40)
        XCTAssertEqual(info.height, 24)
        XCTAssertEqual(info.uti, "public.png")
        XCTAssertFalse(info.isMonochrome)
        XCTAssertEqual(info.bitsPerComponent, 8)
    }

    func testStreamingSixteenBitPNG() throws {
        let dir = try TestSupport.makeTempDir("scanjet-png16")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 8, samplesPerPixel: 3, dpi: 300, bitsPerSample: 16)
        for _ in 0..<4 {
            let row = [UInt16](repeating: 0x8000, count: 8 * 3)
            try writer.write(row16: row)
        }
        try writer.finish()
        var request = ScanRequest(format: .png)
        request.colorDepth = .billions
        let output = dir.appendingPathComponent("out.png")
        try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 8)
        XCTAssertEqual(info.height, 4)
        XCTAssertEqual(info.bitsPerComponent, 16)
        XCTAssertEqual(info.uti, "public.png")
    }

    func testPreviewDownscales() throws {
        let dir = try TestSupport.makeTempDir("scanjet-preview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        try TestSupport.writeRGBTIFF(to: source, width: 800, height: 400)
        let preview = try ImageExporter.makePreviewPNG(from: source, maxDimension: 100)
        defer { try? FileManager.default.removeItem(at: preview) }
        let info = try TestSupport.inspectRaster(preview)
        XCTAssertEqual(info.width, 100)
        XCTAssertEqual(info.height, 50)
        XCTAssertEqual(info.uti, "public.png")
    }

    func testPNGRowWriterSixteenBit() throws {
        let dir = try TestSupport.makeTempDir("scanjet-png-row")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("direct.png")
        let writer = try PNGRowWriter(path: output.path, width: 8, height: 4,
                                      samplesPerPixel: 3, bitsPerSample: 16, dpi: 2400)
        for _ in 0..<4 {
            try writer.write(row16: [UInt16](repeating: 0x8000, count: 8 * 3))
        }
        _ = try writer.finish()
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 8)
        XCTAssertEqual(info.height, 4)
        XCTAssertEqual(info.bitsPerComponent, 16)
        XCTAssertEqual(info.uti, "public.png")
    }

    func testStreamingJPEGAndRotationFromWriterTIFF() throws {
        let dir = try TestSupport.makeTempDir("scanjet-jpeg-rot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 32, samplesPerPixel: 3, dpi: 75, bitsPerSample: 8)
        for y in 0..<16 {
            var row = [UInt8](repeating: 0, count: 32 * 3)
            for x in 0..<32 {
                row[x * 3] = UInt8(x * 4)
                row[x * 3 + 1] = UInt8(y * 8)
                row[x * 3 + 2] = 40
            }
            try writer.write(row: row)
        }
        try writer.finish()

        let jpeg = dir.appendingPathComponent("out.jpg")
        try ImageExporter.export(sourceTIFF: source, request: ScanRequest(format: .jpeg), outputURL: jpeg)
        let jpegInfo = try TestSupport.inspectRaster(jpeg)
        XCTAssertEqual(jpegInfo.width, 32)
        XCTAssertEqual(jpegInfo.height, 16)
        XCTAssertEqual(jpegInfo.uti, "public.jpeg")

        let rotated = dir.appendingPathComponent("rot.png")
        try ImageExporter.export(sourceTIFF: source, request: ScanRequest(kind: .colour, orientation: .deg90, format: .png),
                                 outputURL: rotated)
        let rot = try TestSupport.inspectRaster(rotated)
        XCTAssertEqual(rot.width, 16)
        XCTAssertEqual(rot.height, 32)
    }

    func testSixteenBitRotate270PNG() throws {
        let dir = try TestSupport.makeTempDir("scanjet-rot270-16")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 4, samplesPerPixel: 3, dpi: 300, bitsPerSample: 16)
        for y in 0..<6 {
            var row = [UInt16](repeating: 0, count: 4 * 3)
            for x in 0..<4 {
                row[x * 3] = UInt16(x * 1000)
                row[x * 3 + 1] = UInt16(y * 2000)
                row[x * 3 + 2] = 0x8000
            }
            try writer.write(row16: row)
        }
        try writer.finish()
        var request = ScanRequest(kind: .colour, orientation: .deg270, format: .png)
        request.colorDepth = .billions
        let output = dir.appendingPathComponent("rot.png")
        try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 6)
        XCTAssertEqual(info.height, 4)
        XCTAssertEqual(info.bitsPerComponent, 16)
        XCTAssertEqual(info.uti, "public.png")
    }

    func testTransposeWriter270MatchesExport() throws {
        let dir = try TestSupport.makeTempDir("scanjet-transpose-writer")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rotated = dir.appendingPathComponent("rot.tiff")
        let writer = try TransposeTIFFWriter(
            path: rotated.path, srcWidth: 4, srcHeight: 6, samplesPerPixel: 3,
            bitsPerSample: 16, dpi: 300, clockwise: false
        )
        for y in 0..<6 {
            var row = [UInt16](repeating: 0, count: 4 * 3)
            for x in 0..<4 {
                row[x * 3] = UInt16(x * 1000)
                row[x * 3 + 1] = UInt16(y * 2000)
                row[x * 3 + 2] = 0x8000
            }
            try writer.write(row16: row)
        }
        _ = try writer.finish()
        guard let info = TIFFPreview.info(of: rotated) else {
            return XCTFail("rotated TIFF is unreadable")
        }
        XCTAssertEqual(info.width, 6)
        XCTAssertEqual(info.height, 4)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.samplesPerPixel, 3)

        var request = ScanRequest(kind: .colour, orientation: .deg0, format: .png)
        request.colorDepth = .billions
        let output = dir.appendingPathComponent("from-writer.png")
        try ImageExporter.export(sourceTIFF: rotated, request: request, outputURL: output)
        let png = try TestSupport.inspectRaster(output)
        XCTAssertEqual(png.width, 6)
        XCTAssertEqual(png.height, 4)
        XCTAssertEqual(png.bitsPerComponent, 16)
    }

    func testStreamingBMPAndGIFFromWriterTIFF() throws {
        let dir = try TestSupport.makeTempDir("scanjet-bmp-gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 12, samplesPerPixel: 3, dpi: 75, bitsPerSample: 8)
        for _ in 0..<8 {
            try writer.write(row: [UInt8](repeating: 90, count: 12 * 3))
        }
        try writer.finish()
        let bmp = dir.appendingPathComponent("out.bmp")
        try ImageExporter.export(sourceTIFF: source, request: ScanRequest(format: .bmp), outputURL: bmp)
        let bmpInfo = try TestSupport.inspectRaster(bmp)
        XCTAssertEqual(bmpInfo.width, 12)
        XCTAssertEqual(bmpInfo.height, 8)

        let gif = dir.appendingPathComponent("out.gif")
        try ImageExporter.export(sourceTIFF: source, request: ScanRequest(format: .gif), outputURL: gif)
        let gifInfo = try TestSupport.inspectRaster(gif)
        XCTAssertEqual(gifInfo.width, 12)
        XCTAssertEqual(gifInfo.height, 8)
        XCTAssertEqual(gifInfo.uti, "com.compuserve.gif")
    }

    func testJPEG2000RowWriterDoesNotWritePNG() throws {
        let dir = try TestSupport.makeTempDir("scanjet-jp2-row")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.jp2")
        let writer: PixelRowWriter
        do {
            writer = try RasterWriter.make(
                format: .jpeg2000, path: output.path, width: 8, height: 4,
                samplesPerPixel: 3, bitsPerSample: 8, dpi: 75
            )
        } catch {
            throw XCTSkip("JPEG 2000 writer unavailable: \(error)")
        }
        for _ in 0..<4 {
            try writer.write(row: [UInt8](repeating: 180, count: 8 * 3))
        }
        do {
            _ = try writer.finish()
        } catch {
            throw XCTSkip("JPEG 2000 encode unavailable: \(error)")
        }
        let bytes = try Data(contentsOf: output)
        XCTAssertFalse(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, 8)
        XCTAssertEqual(info.height, 4)
        XCTAssertEqual(info.uti, "public.jpeg-2000")
    }
}
