import Foundation

/// Cheap live view of the CIS stream: only preview-sized samples, never the full frame.
final class LiveCISPreview {
    private let mode: ScanMode
    private let scale: Int
    private let color: Bool
    private let shading: Shading?
    private let lut: [UInt8]
    private let skipRaw: Int
    private let cropStart: Int
    private let cropEnd: Int
    private let expectedOut: Int
    private let factor: Int
    let outW: Int
    let outH: Int
    private let rgbRowBytes: Int
    private var leftover = [UInt8]()
    private var cisRows = 0
    private var pixels: [UInt8]
    private var dirtyY0: Int?
    private var dirtyY1 = 0
    private var lastEmit = Date.distantPast
    private let minInterval: TimeInterval = 0.2

    init(mode: ScanMode, scale: Int, color: Bool, shading: Shading?,
         lut: [UInt8],
         skipRaw: Int, cropStart: Int, cropEnd: Int, expectedOut: Int,
         maxDimension: Int = 1600) {
        precondition(lut.count == 65536, "tone LUT must cover 16-bit samples")
        self.mode = mode
        self.scale = max(1, scale)
        self.color = color
        self.shading = shading
        self.lut = lut
        self.skipRaw = max(0, skipRaw)
        self.cropStart = max(0, min(mode.samplesPerLine, cropStart))
        self.cropEnd = min(mode.samplesPerLine, max(cropStart + 1, cropEnd))
        self.expectedOut = max(1, expectedOut)
        let srcW = max(1, (self.cropEnd - self.cropStart) / self.scale)
        let srcH = self.expectedOut
        let factor = max(1, (max(srcW, srcH) + maxDimension - 1) / maxDimension)
        self.factor = factor
        self.outW = max(1, srcW / factor)
        self.outH = max(1, srcH / factor)
        self.rgbRowBytes = mode.bytesPerLine * 3
        self.pixels = [UInt8](repeating: 0, count: outW * outH * 4)
        leftover.reserveCapacity(rgbRowBytes)
    }

    func ingest(_ data: [UInt8]) -> LivePreviewBand? {
        guard !data.isEmpty else { return maybeEmit(force: false) }
        data.withUnsafeBufferPointer { buf in
            consume(buf)
        }
        return maybeEmit(force: false)
    }

    func flush() -> LivePreviewBand? {
        maybeEmit(force: true)
    }

    private func consume(_ buf: UnsafeBufferPointer<UInt8>) {
        var offset = 0
        if leftover.count > 0 {
            let need = rgbRowBytes - leftover.count
            if buf.count - offset < need {
                leftover.append(contentsOf: buf[offset..<buf.count])
                return
            }
            leftover.append(contentsOf: buf[offset..<(offset + need)])
            leftover.withUnsafeBufferPointer { consumeRGB($0) }
            leftover.removeAll(keepingCapacity: true)
            offset += need
        }
        while buf.count - offset >= rgbRowBytes {
            let row = UnsafeBufferPointer(rebasing: buf[offset..<(offset + rgbRowBytes)])
            consumeRGB(row)
            offset += rgbRowBytes
        }
        if offset < buf.count {
            leftover.append(contentsOf: buf[offset..<buf.count])
        }
    }

    private func consumeRGB(_ row: UnsafeBufferPointer<UInt8>) {
        let srcIndex = cisRows
        cisRows += 1
        if srcIndex < skipRaw { return }
        let outY = (srcIndex - skipRaw) / scale
        guard outY < expectedOut, outY % factor == 0 else { return }
        let py = outY / factor
        guard py < outH else { return }

        let width = mode.samplesPerLine
        let bpl = mode.bytesPerLine
        let step = factor * scale
        let target = UInt32(shading?.target ?? 0)

        for ox in 0..<outW {
            let x = min(cropEnd - 1, cropStart + ox * step)
            let mirrored = width - 1 - x
            func sample(_ channel: Int) -> UInt8 {
                let i = channel * bpl + mirrored * 2
                var value = UInt32(row[i]) << 8 | UInt32(row[i + 1])
                if let reference = shading?.reference[channel] {
                    let ref = UInt32(reference[mirrored])
                    if ref > 256 {
                        value = min(65535, value * target / ref)
                    }
                }
                return lut[Int(value)]
            }
            let r: UInt8
            let g: UInt8
            let b: UInt8
            if color {
                r = sample(0)
                g = sample(1)
                b = sample(2)
            } else {
                let y = (77 * Int(sample(0)) + 150 * Int(sample(1)) + 29 * Int(sample(2))) >> 8
                r = UInt8(y)
                g = r
                b = r
            }
            let dst = (py * outW + ox) * 4
            pixels[dst] = r
            pixels[dst + 1] = g
            pixels[dst + 2] = b
            pixels[dst + 3] = 255
        }
        if dirtyY0 == nil { dirtyY0 = py }
        dirtyY1 = py + 1
    }

    private func maybeEmit(force: Bool) -> LivePreviewBand? {
        guard let y0 = dirtyY0, dirtyY1 > y0 else { return nil }
        if !force && Date().timeIntervalSince(lastEmit) < minInterval {
            return nil
        }
        let rows = dirtyY1 - y0
        let bpr = outW * 4
        let slice = pixels[(y0 * bpr)..<(dirtyY1 * bpr)]
        dirtyY0 = nil
        lastEmit = Date()
        return LivePreviewBand(width: outW, height: outH, y: y0, rows: rows, rgba: Data(slice))
    }
}
