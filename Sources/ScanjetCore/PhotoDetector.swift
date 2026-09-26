import Foundation
import CoreGraphics
import Vision

public enum PhotoDetector {
    /// 35 mm full-frame pitch including a typical inter-frame gap, millimetres.
    public static let filmFramePitchMM = PhotoFilmFormat.mm35.framePitchMM
    /// Vision can trap in headless test runs; blob detection still runs.
    public static var usesVision = true

    public static func detect(
        image: CGImage,
        capture: ScanRegion,
        settings: PhotoSettings
    ) -> PhotoDetectionResult {
        switch settings.layout {
        case .prints:
            return PhotoDetectionResult(frames: [fallbackFrame(capture)], stripBounds: nil)
        case .filmStrip:
            let visionFrames = detectVision(image: image, capture: capture, settings: settings)
            let blobFrames = detectBlobs(image: image, capture: capture, settings: settings)
            let strip = findFilmStrip(
                image: image, capture: capture, blobs: blobFrames, vision: visionFrames,
                format: settings.filmFormat
            )
            let format = settings.filmFormat.resolved(for: strip)
            let along = max(strip.widthMM, strip.heightMM)
            let count = estimatedFrameCount(stripLengthMM: along, format: format)
            let frames = splitStrip(bounds: strip, count: count)
            return PhotoDetectionResult(frames: frames, stripBounds: strip, filmFormat: format)
        }
    }

    public static func splitStrip(bounds: ScanRegion, count: Int) -> [PhotoFrame] {
        let n = max(1, count)
        let horizontal = bounds.widthMM >= bounds.heightMM
        var frames: [PhotoFrame] = []
        if horizontal {
            let width = bounds.widthMM / Double(n)
            for i in 0..<n {
                frames.append(PhotoFrame(region: ScanRegion(
                    xMM: bounds.xMM + Double(i) * width,
                    yMM: bounds.yMM,
                    widthMM: width,
                    heightMM: bounds.heightMM
                )))
            }
        } else {
            let height = bounds.heightMM / Double(n)
            for i in 0..<n {
                frames.append(PhotoFrame(region: ScanRegion(
                    xMM: bounds.xMM,
                    yMM: bounds.yMM + Double(i) * height,
                    widthMM: bounds.widthMM,
                    heightMM: height
                )))
            }
        }
        return PhotoGeometry.sorted(frames)
    }

    public static func estimatedFrameCount(
        stripLengthMM: Double,
        format: PhotoFilmFormat = .mm35
    ) -> Int {
        max(1, Int((stripLengthMM / format.framePitchMM).rounded()))
    }

    public static func estimatedFrameCount(strip: ScanRegion, format: PhotoFilmFormat) -> Int {
        let resolved = format.resolved(for: strip)
        return estimatedFrameCount(
            stripLengthMM: max(strip.widthMM, strip.heightMM), format: resolved
        )
    }

    private static func fallbackFrame(_ capture: ScanRegion) -> PhotoFrame {
        PhotoFrame(region: capture)
    }

    private static func aspect(_ region: ScanRegion) -> Double {
        max(region.widthMM, region.heightMM) / max(1, min(region.widthMM, region.heightMM))
    }

    /// Isolate the film ribbon. Do not fall back to the whole page — that splits A4 into fake frames.
    private static func findFilmStrip(
        image: CGImage,
        capture: ScanRegion,
        blobs: [PhotoFrame],
        vision: [PhotoFrame],
        format: PhotoFilmFormat
    ) -> ScanRegion {
        let widths: [Double]
        if format == .auto {
            widths = [35, 61.5, 16, 46]
        } else {
            widths = [format.stockWidthMM]
        }

        let elongated = (blobs + vision).map(\.region).filter {
            aspect($0) >= 2.2 && $0.areaMM < capture.areaMM * 0.45
        }
        if let match = bestStrip(in: elongated, stockWidths: widths) {
            return match
        }
        if let band = detectContentBand(image: image, capture: capture, stockWidths: widths) {
            return band
        }
        if let longest = elongated.max(by: { aspect($0) < aspect($1) }) {
            return longest
        }
        if let blob = blobs.max(by: { $0.region.areaMM < $1.region.areaMM }),
           blob.region.areaMM < capture.areaMM * 0.45 {
            return blob.region
        }
        return capture
    }

    private static func bestStrip(in regions: [ScanRegion], stockWidths: [Double]) -> ScanRegion? {
        var best: (ScanRegion, Double)?
        for region in regions {
            let across = min(region.widthMM, region.heightMM)
            guard let width = stockWidths.min(by: { abs($0 - across) < abs($1 - across) }) else { continue }
            let error = abs(across - width) / width
            guard error < 0.55 else { continue }
            let score = aspect(region) - error * 4
            if best == nil || score > best!.1 {
                best = (region, score)
            }
        }
        return best?.0
    }

    /// A film-stock-thick band, dark on a light lid or light on a dark lid.
    private static func detectContentBand(
        image: CGImage,
        capture: ScanRegion,
        stockWidths: [Double]
    ) -> ScanRegion? {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let rowMeans = (0..<height).map { y -> Double in
            var sum = 0
            let row = y * width
            for x in 0..<width { sum += Int(pixels[row + x]) }
            return Double(sum) / Double(width)
        }
        let colMeans = (0..<width).map { x -> Double in
            var sum = 0
            for y in 0..<height { sum += Int(pixels[y * width + x]) }
            return Double(sum) / Double(height)
        }

        var best: (band: Band, horizontal: Bool)?
        for brighter in [false, true] {
            if let band = bestBand(
                profile: rowMeans, captureAlong: capture.heightMM,
                origin: capture.yMM, stockWidths: stockWidths, brighterIsContent: brighter
            ) {
                if best == nil || band.score > best!.band.score {
                    best = (band, true)
                }
            }
            if let band = bestBand(
                profile: colMeans, captureAlong: capture.widthMM,
                origin: capture.xMM, stockWidths: stockWidths, brighterIsContent: brighter
            ) {
                if best == nil || band.score > best!.band.score {
                    best = (band, false)
                }
            }
        }
        guard let best else { return nil }

        if best.horizontal {
            let span = contentSpan(
                pixels: pixels, width: width, height: height,
                alongY: true, start: best.band.pixelStart, end: best.band.pixelEnd,
                brighterIsContent: best.band.brighterIsContent
            )
            let x0 = capture.xMM + Double(span.start) / Double(width) * capture.widthMM
            let x1 = capture.xMM + Double(span.end) / Double(width) * capture.widthMM
            return ScanRegion(
                xMM: x0, yMM: best.band.originMM,
                widthMM: max(10, x1 - x0), heightMM: best.band.thicknessMM
            ).clamped(to: capture)
        }
        let span = contentSpan(
            pixels: pixels, width: width, height: height,
            alongY: false, start: best.band.pixelStart, end: best.band.pixelEnd,
            brighterIsContent: best.band.brighterIsContent
        )
        let y0 = capture.yMM + Double(span.start) / Double(height) * capture.heightMM
        let y1 = capture.yMM + Double(span.end) / Double(height) * capture.heightMM
        return ScanRegion(
            xMM: best.band.originMM, yMM: y0,
            widthMM: best.band.thicknessMM, heightMM: max(10, y1 - y0)
        ).clamped(to: capture)
    }

    private struct Band {
        var pixelStart: Int
        var pixelEnd: Int
        var originMM: Double
        var thicknessMM: Double
        var score: Double
        var brighterIsContent: Bool
    }

    private static func bestBand(
        profile: [Double],
        captureAlong: Double,
        origin: Double,
        stockWidths: [Double],
        brighterIsContent: Bool
    ) -> Band? {
        let n = profile.count
        guard n > 8 else { return nil }
        var prefix = [0.0]
        prefix.reserveCapacity(n + 1)
        for value in profile {
            prefix.append(prefix[prefix.count - 1] + value)
        }
        let sorted = profile.sorted()
        let background = brighterIsContent ? sorted[n / 4] : sorted[n * 3 / 4]
        var best: Band?
        for stock in stockWidths {
            for scale in [0.85, 1.0, 1.15] {
                let window = max(4, Int((stock * scale / captureAlong * Double(n)).rounded()))
                guard window < n else { continue }
                for start in 0...(n - window) {
                    let end = start + window
                    let mean = (prefix[end] - prefix[start]) / Double(window)
                    let contrast = brighterIsContent ? mean - background : background - mean
                    guard contrast > 12 else { continue }
                    let thicknessMM = Double(window) / Double(n) * captureAlong
                    let error = abs(thicknessMM - stock) / stock
                    let score = contrast * (1.2 - min(1, error))
                    if best == nil || score > best!.score {
                        best = Band(
                            pixelStart: start,
                            pixelEnd: end,
                            originMM: origin + Double(start) / Double(n) * captureAlong,
                            thicknessMM: thicknessMM,
                            score: score,
                            brighterIsContent: brighterIsContent
                        )
                    }
                }
            }
        }
        return best
    }

    private static func contentSpan(
        pixels: [UInt8], width: Int, height: Int, alongY: Bool, start: Int, end: Int,
        brighterIsContent: Bool
    ) -> (start: Int, end: Int) {
        let lim = alongY ? width : height
        var colSum = [Int](repeating: 0, count: lim)
        var colCount = [Int](repeating: 0, count: lim)
        if alongY {
            for y in start..<min(end, height) {
                let row = y * width
                for x in 0..<width {
                    colSum[x] += Int(pixels[row + x])
                    colCount[x] += 1
                }
            }
        } else {
            for x in start..<min(end, width) {
                for y in 0..<height {
                    colSum[y] += Int(pixels[y * width + x])
                    colCount[y] += 1
                }
            }
        }
        let means = (0..<lim).map { colCount[$0] == 0 ? 128.0 : Double(colSum[$0]) / Double(colCount[$0]) }
        let sorted = means.sorted()
        let background = brighterIsContent ? sorted[lim / 4] : sorted[lim * 3 / 4]
        var first = 0
        var last = lim - 1
        for i in 0..<lim {
            let contrast = brighterIsContent ? means[i] - background : background - means[i]
            if contrast > 10 {
                first = i
                break
            }
        }
        for i in stride(from: lim - 1, through: 0, by: -1) {
            let contrast = brighterIsContent ? means[i] - background : background - means[i]
            if contrast > 10 {
                last = i
                break
            }
        }
        return (max(0, first - 2), min(lim, last + 3))
    }

    private static func detectVision(
        image: CGImage,
        capture: ScanRegion,
        settings: PhotoSettings
    ) -> [PhotoFrame] {
        guard usesVision else { return [] }
        let minMM = settings.layout == .prints ? 40.0 : 6.0
        let minSize = Float(minMM / max(capture.widthMM, capture.heightMM))
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = max(0.02, min(0.8, minSize))
        request.maximumObservations = 20
        request.quadratureTolerance = 25
        request.minimumConfidence = 0.3
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        let width = image.width
        let height = image.height
        var frames: [PhotoFrame] = []
        for observation in observations {
            let corners = [
                imagePoint(observation.topLeft, width: width, height: height),
                imagePoint(observation.topRight, width: width, height: height),
                imagePoint(observation.bottomRight, width: width, height: height),
                imagePoint(observation.bottomLeft, width: width, height: height)
            ]
            let minX = corners.map(\.x).min() ?? 0
            let minY = corners.map(\.y).min() ?? 0
            let maxX = corners.map(\.x).max() ?? 0
            let maxY = corners.map(\.y).max() ?? 0
            let pixel = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard pixel.width > 4, pixel.height > 4 else { continue }
            let region = PhotoGeometry.region(
                fromPixel: pixel, capture: capture, imageWidth: width, imageHeight: height
            ).expanded(byMM: 0.5).clamped(to: capture)
            if min(region.widthMM, region.heightMM) < minMM * 0.6 { continue }
            if settings.layout.isFilm {
                let long = max(region.widthMM, region.heightMM)
                let short = min(region.widthMM, region.heightMM)
                if region.areaMM > capture.areaMM * 0.45 { continue }
                if long / max(1, short) < 2.2 { continue }
            }
            let dx = observation.topRight.x - observation.topLeft.x
            let dy = (1 - observation.topRight.y) - (1 - observation.topLeft.y)
            let angle = atan2(dy, dx) * 180 / .pi
            frames.append(PhotoFrame(region: region, angleDegrees: angle))
        }
        return frames
    }

    private static func imagePoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height))
    }

    private static func detectBlobs(
        image: CGImage,
        capture: ScanRegion,
        settings: PhotoSettings
    ) -> [PhotoFrame] {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }

        let background = borderMedian(pixels, width: width, height: height)
        let delta: UInt8 = settings.layout.isFilm ? 12 : 18
        var mask = [UInt8](repeating: 0, count: width * height)
        for i in 0..<pixels.count {
            mask[i] = background > delta && pixels[i] < background - delta ? 1 : 0
        }

        let boxes = labeledBoxes(mask: mask, width: width, height: height)
        let minMM = settings.layout == .prints ? 40.0 : 6.0
        var frames: [PhotoFrame] = []
        for box in boxes {
            let region = PhotoGeometry.region(
                fromPixel: box, capture: capture, imageWidth: width, imageHeight: height
            ).expanded(byMM: 0.5).clamped(to: capture)
            if min(region.widthMM, region.heightMM) < minMM * 0.6 { continue }
            if region.areaMM > capture.areaMM * (settings.layout.isFilm ? 0.45 : 0.95) { continue }
            frames.append(PhotoFrame(region: region))
        }
        return frames
    }

    private static func borderMedian(_ pixels: [UInt8], width: Int, height: Int) -> UInt8 {
        let border = max(2, min(width, height) / 40)
        var samples: [UInt8] = []
        samples.reserveCapacity((width + height) * border)
        for y in 0..<height {
            for x in 0..<width {
                if x >= border && x < width - border && y >= border && y < height - border {
                    continue
                }
                samples.append(pixels[y * width + x])
            }
        }
        guard !samples.isEmpty else { return 220 }
        samples.sort()
        return samples[samples.count / 2]
    }

    private static func labeledBoxes(mask: [UInt8], width: Int, height: Int) -> [CGRect] {
        var parent = Array(0..<(width * height))
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let pa = find(a)
            let pb = find(b)
            if pa != pb { parent[pb] = pa }
        }

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard mask[i] == 1 else { continue }
                if x > 0, mask[i - 1] == 1 { union(i, i - 1) }
                if y > 0, mask[i - width] == 1 { union(i, i - width) }
            }
        }

        var minX: [Int: Int] = [:]
        var minY: [Int: Int] = [:]
        var maxX: [Int: Int] = [:]
        var maxY: [Int: Int] = [:]
        var area: [Int: Int] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard mask[i] == 1 else { continue }
                let root = find(i)
                minX[root] = min(minX[root] ?? x, x)
                minY[root] = min(minY[root] ?? y, y)
                maxX[root] = max(maxX[root] ?? x, x)
                maxY[root] = max(maxY[root] ?? y, y)
                area[root, default: 0] += 1
            }
        }

        let minArea = max(80, (width * height) / 400)
        var boxes: [CGRect] = []
        for (root, count) in area where count >= minArea {
            guard let x0 = minX[root], let y0 = minY[root], let x1 = maxX[root], let y1 = maxY[root] else {
                continue
            }
            boxes.append(CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
        }
        return boxes
    }
}
