import Foundation
import CoreGraphics

/// Builds a small 8-bit preview while the full frame is written row by row.
final class PreviewSampler {
    private let factor: Int
    private let outW: Int
    private let outH: Int
    private let sourceWidth: Int
    private let samplesPerPixel: Int
    private var pixels: [UInt8]
    private var sourceY = 0

    init(sourceWidth: Int, sourceHeight: Int, samplesPerPixel: Int, maxDimension: Int = 1600) {
        let factor = max(1, (max(sourceWidth, sourceHeight) + maxDimension - 1) / maxDimension)
        self.factor = factor
        self.sourceWidth = sourceWidth
        self.samplesPerPixel = samplesPerPixel
        self.outW = max(1, sourceWidth / factor)
        self.outH = max(1, sourceHeight / factor)
        self.pixels = [UInt8](repeating: 0, count: outW * outH * 4)
    }

    func add(row: [UInt8]) {
        consume(srcY: sourceY) { ox in
            sampleRGB8(row, x: min(sourceWidth - 1, ox * factor))
        }
        sourceY += 1
    }

    func add(row16: [UInt16]) {
        consume(srcY: sourceY) { ox in
            sampleRGB16(row16, x: min(sourceWidth - 1, ox * factor))
        }
        sourceY += 1
    }

    func makeImage() -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: outW * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        return ctx.makeImage()
    }

    private func consume(srcY: Int, sample: (Int) -> (UInt8, UInt8, UInt8)) {
        guard srcY % factor == 0 else { return }
        let oy = srcY / factor
        guard oy < outH else { return }
        for ox in 0..<outW {
            let (r, g, b) = sample(ox)
            let dst = (oy * outW + ox) * 4
            pixels[dst] = r
            pixels[dst + 1] = g
            pixels[dst + 2] = b
            pixels[dst + 3] = 255
        }
    }

    private func sampleRGB8(_ row: [UInt8], x: Int) -> (UInt8, UInt8, UInt8) {
        if samplesPerPixel == 3 {
            let i = x * 3
            return (row[i], row[i + 1], row[i + 2])
        }
        let v = row[x]
        return (v, v, v)
    }

    private func sampleRGB16(_ row: [UInt16], x: Int) -> (UInt8, UInt8, UInt8) {
        if samplesPerPixel == 3 {
            let i = x * 3
            return (UInt8(row[i] >> 8), UInt8(row[i + 1] >> 8), UInt8(row[i + 2] >> 8))
        }
        let v = UInt8(row[x] >> 8)
        return (v, v, v)
    }
}

final class PreviewTappingWriter: PixelRowWriter {
    private let inner: PixelRowWriter
    private let preview: PreviewSampler

    init(inner: PixelRowWriter, preview: PreviewSampler) {
        self.inner = inner
        self.preview = preview
    }

    func write(row: [UInt8]) throws {
        preview.add(row: row)
        try inner.write(row: row)
    }

    func write(row16: [UInt16]) throws {
        preview.add(row16: row16)
        try inner.write(row16: row16)
    }

    func finish() throws -> Int {
        try inner.finish()
    }
}
