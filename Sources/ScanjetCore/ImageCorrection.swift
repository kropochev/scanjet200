import Foundation
import CoreGraphics
import AppKit

/// Image Capture–style tone controls. Sliders are bipolar in `[-1, 1]`; 0 is the default.
public enum ImageCorrectionMode: String, CaseIterable, Sendable, Hashable {
    case none
    case manual
}

public struct ImageCorrection: Equatable, Sendable {
    public var mode: ImageCorrectionMode = .none
    public var brightness: Double = 0
    public var tint: Double = 0
    public var temperature: Double = 0
    public var saturation: Double = 0

    public init(
        mode: ImageCorrectionMode = .none,
        brightness: Double = 0,
        tint: Double = 0,
        temperature: Double = 0,
        saturation: Double = 0
    ) {
        self.mode = mode
        self.brightness = brightness
        self.tint = tint
        self.temperature = temperature
        self.saturation = saturation
    }

    public static let identity = ImageCorrection()

    /// Manual mode with at least one slider off centre.
    public var shouldApply: Bool {
        mode == .manual && (adjusted(brightness) || adjusted(tint)
            || adjusted(temperature) || adjusted(saturation))
    }

    public var isAtDefaults: Bool {
        !adjusted(brightness) && !adjusted(tint) && !adjusted(temperature) && !adjusted(saturation)
    }

    public mutating func restoreDefaults() {
        brightness = 0
        tint = 0
        temperature = 0
        saturation = 0
    }

    /// Apply in 0…1 RGB. Identity when `shouldApply` is false.
    public func apply(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        transform.apply(r, g, b)
    }

    public func apply8(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        transform.apply8(r, g, b)
    }

    public func apply16(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> (UInt16, UInt16, UInt16) {
        transform.apply16(r, g, b)
    }

    public func applyGray8(_ value: UInt8) -> UInt8 {
        transform.applyGray8(value)
    }

    public func applyGray16(_ value: UInt16) -> UInt16 {
        transform.applyGray16(value)
    }

    /// Draw into a known RGB bitmap and run the same matrix used for scan rows.
    public func applying(to image: CGImage) -> CGImage {
        applying(to: image, rowCount: image.height)
    }

    /// Same as `applying(to:)`, but only the first `rowCount` rows are filtered.
    /// Live scan uses this so the still-black area below the carriage stays black.
    public func applying(to image: CGImage, rowCount: Int) -> CGImage {
        guard shouldApply else { return image }
        let w = image.width
        let h = image.height
        let rows = min(h, max(0, rowCount))
        guard rows > 0 else { return image }
        let bpc = image.bitsPerComponent >= 16 ? 16 : 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alpha = CGImageAlphaInfo.noneSkipLast
        var bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue)
        if bpc == 16 {
            bitmapInfo.insert(.byteOrder16Little)
        }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: bpc,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ), let data = ctx.data else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let transform = self.transform
        if bpc == 16 {
            transform.applyRGB16X(data, width: w, height: rows, bytesPerRow: ctx.bytesPerRow)
        } else {
            transform.applyRGB8X(data, width: w, height: rows, bytesPerRow: ctx.bytesPerRow)
        }
        return ctx.makeImage() ?? image
    }

    /// Filter the first `rowCount` rows of a top-down 8-bit RGBA/RGBX buffer in place.
    public func applyToRGBA8(_ data: UnsafeMutableRawPointer, width: Int, rowCount: Int, bytesPerRow: Int) {
        guard shouldApply, rowCount > 0, width > 0 else { return }
        transform.applyRGB8X(data, width: width, height: rowCount, bytesPerRow: bytesPerRow)
    }

    public func applying(to image: NSImage) -> NSImage {
        guard shouldApply else { return image }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image
        }
        let out = applying(to: cg)
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    var transform: ColorTransform {
        ColorTransform(
            brightness: clamped(brightness),
            tint: clamped(tint),
            temperature: clamped(temperature),
            saturation: clamped(saturation),
            enabled: shouldApply
        )
    }

    private func adjusted(_ value: Double) -> Bool { abs(value) > 1e-6 }
    private func clamped(_ value: Double) -> Double { min(1, max(-1, value)) }
}

/// 3×3 colour matrix plus an additive brightness bias, in 0…1 RGB.
struct ColorTransform: Equatable {
    var m00, m01, m02: Double
    var m10, m11, m12: Double
    var m20, m21, m22: Double
    var bias: Double

    init(brightness: Double, tint: Double, temperature: Double, saturation: Double, enabled: Bool) {
        if !enabled {
            m00 = 1; m01 = 0; m02 = 0
            m10 = 0; m11 = 1; m12 = 0
            m20 = 0; m21 = 0; m22 = 1
            bias = 0
            return
        }

        // Temperature: warm raises R / lowers B. Tint: green vs magenta.
        let t = temperature * 0.35
        let tn = tint * 0.25
        let rScale = (1 + t) * (1 - 0.5 * tn)
        let gScale = 1 + tn
        let bScale = (1 - t) * (1 - 0.5 * tn)

        let s = 1 + saturation
        let wr = 0.2126, wg = 0.7152, wb = 0.0722
        let oneMinus = 1 - s
        let sR = s + oneMinus * wr
        let sG = s + oneMinus * wg
        let sB = s + oneMinus * wb
        let kR = oneMinus * wr
        let kG = oneMinus * wg
        let kB = oneMinus * wb

        m00 = sR * rScale; m01 = kG * gScale; m02 = kB * bScale
        m10 = kR * rScale; m11 = sG * gScale; m12 = kB * bScale
        m20 = kR * rScale; m21 = kG * gScale; m22 = sB * bScale
        bias = brightness * 0.5
    }

    func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (
            clamp01(m00 * r + m01 * g + m02 * b + bias),
            clamp01(m10 * r + m11 * g + m12 * b + bias),
            clamp01(m20 * r + m21 * g + m22 * b + bias)
        )
    }

    func apply8(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let (or, og, ob) = apply(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        return (toUInt8(or), toUInt8(og), toUInt8(ob))
    }

    func apply16(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> (UInt16, UInt16, UInt16) {
        let scale = 1.0 / 65535.0
        let (or, og, ob) = apply(Double(r) * scale, Double(g) * scale, Double(b) * scale)
        return (toUInt16(or), toUInt16(og), toUInt16(ob))
    }

    func applyGray8(_ value: UInt8) -> UInt8 {
        toUInt8(clamp01(Double(value) / 255 + bias))
    }

    func applyGray16(_ value: UInt16) -> UInt16 {
        toUInt16(clamp01(Double(value) / 65535 + bias))
    }

    func applyRGB8X(_ data: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let i = x * 4
                let (r, g, b) = apply8(row[i], row[i + 1], row[i + 2])
                row[i] = r
                row[i + 1] = g
                row[i + 2] = b
            }
        }
    }

    func applyRGB16X(_ data: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let ptr = data.assumingMemoryBound(to: UInt16.self)
        let stride = bytesPerRow / 2
        for y in 0..<height {
            let row = ptr + y * stride
            for x in 0..<width {
                let i = x * 4
                let (r, g, b) = apply16(row[i], row[i + 1], row[i + 2])
                row[i] = r
                row[i + 1] = g
                row[i + 2] = b
            }
        }
    }
}

final class CorrectionWriter: PixelRowWriter {
    private let inner: PixelRowWriter
    private let transform: ColorTransform
    private let samplesPerPixel: Int
    private var scratch8 = [UInt8]()
    private var scratch16 = [UInt16]()

    init(_ inner: PixelRowWriter, correction: ImageCorrection, samplesPerPixel: Int) {
        self.inner = inner
        self.transform = correction.transform
        self.samplesPerPixel = samplesPerPixel
    }

    func write(row: [UInt8]) throws {
        try inner.write(row: map8(row))
    }

    func write(row16: [UInt16]) throws {
        try inner.write(row16: map16(row16))
    }

    func finish() throws -> Int {
        try inner.finish()
    }

    private func map8(_ row: [UInt8]) -> [UInt8] {
        scratch8.removeAll(keepingCapacity: true)
        scratch8.reserveCapacity(row.count)
        if samplesPerPixel == 1 {
            for value in row {
                scratch8.append(transform.applyGray8(value))
            }
            return scratch8
        }
        var i = 0
        while i + 2 < row.count {
            let (r, g, b) = transform.apply8(row[i], row[i + 1], row[i + 2])
            scratch8.append(r)
            scratch8.append(g)
            scratch8.append(b)
            i += 3
        }
        while i < row.count {
            scratch8.append(row[i])
            i += 1
        }
        return scratch8
    }

    private func map16(_ row: [UInt16]) -> [UInt16] {
        scratch16.removeAll(keepingCapacity: true)
        scratch16.reserveCapacity(row.count)
        if samplesPerPixel == 1 {
            for value in row {
                scratch16.append(transform.applyGray16(value))
            }
            return scratch16
        }
        var i = 0
        while i + 2 < row.count {
            let (r, g, b) = transform.apply16(row[i], row[i + 1], row[i + 2])
            scratch16.append(r)
            scratch16.append(g)
            scratch16.append(b)
            i += 3
        }
        while i < row.count {
            scratch16.append(row[i])
            i += 1
        }
        return scratch16
    }
}

private func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

private func toUInt8(_ value: Double) -> UInt8 {
    UInt8(min(255, max(0, value * 255 + 0.5)))
}

private func toUInt16(_ value: Double) -> UInt16 {
    UInt16(min(65535, max(0, value * 65535 + 0.5)))
}
