import Foundation
import CScanjetUSB

/// Writes a 90°/270° rotated uncompressed TIFF while the decoder emits unrotated rows.
final class TransposeTIFFWriter: PixelRowWriter {
    private var writer: OpaquePointer?
    private let url: URL
    private let destWidth: Int
    private let destHeight: Int
    private let samplesPerPixel: Int
    private let bitsPerSample: Int
    private let dpi: Int
    private let stripBytes: Int

    init(path: String, srcWidth: Int, srcHeight: Int, samplesPerPixel: Int,
         bitsPerSample: Int, dpi: Int, clockwise: Bool) throws {
        precondition(bitsPerSample == 8 || bitsPerSample == 16)
        self.url = URL(fileURLWithPath: path)
        self.destWidth = srcHeight
        self.destHeight = srcWidth
        self.samplesPerPixel = samplesPerPixel
        self.bitsPerSample = bitsPerSample
        self.dpi = dpi
        let bpp = samplesPerPixel * (bitsPerSample / 8)
        self.stripBytes = srcWidth * srcHeight * bpp

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let opened = scanjet_transpose_writer_open(path, UInt32(srcWidth), UInt32(srcHeight),
                                                         Int32(bpp), clockwise ? 1 : 0) else {
            throw ScanjetError.io(String(cString: scanjet_transpose_last_error()))
        }
        self.writer = opened
    }

    deinit {
        if let writer {
            _ = scanjet_transpose_writer_close(writer)
        }
    }

    func write(row: [UInt8]) throws {
        try writeBytes(row)
    }

    func writePackedLE16(_ bytes: [UInt8]) throws {
        try writeBytes(bytes)
    }

    func write(row16: [UInt16]) throws {
        guard let writer else {
            throw ScanjetError.io("rotate writer already closed")
        }
        let rc = row16.withUnsafeBufferPointer { buf in
            scanjet_transpose_writer_row16(writer, buf.baseAddress, buf.count)
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_transpose_last_error()))
        }
    }

    func finish() throws -> Int {
        guard let current = writer else { return destHeight }
        writer = nil
        guard scanjet_transpose_writer_close(current) == 0 else {
            throw ScanjetError.io(String(cString: scanjet_transpose_last_error()))
        }
        try TIFFWriter.writeIFD(to: url, width: destWidth, height: destHeight,
                                samplesPerPixel: samplesPerPixel, bitsPerSample: bitsPerSample,
                                dpi: dpi, stripBytes: stripBytes)
        return destHeight
    }

    private func writeBytes(_ row: [UInt8]) throws {
        guard let writer else {
            throw ScanjetError.io("rotate writer already closed")
        }
        let rc = row.withUnsafeBytes { ptr in
            scanjet_transpose_writer_row(writer, ptr.bindMemory(to: UInt8.self).baseAddress, ptr.count)
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_transpose_last_error()))
        }
    }
}
