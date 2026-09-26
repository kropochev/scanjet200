import SwiftUI
import ScanjetCore

enum GlassGeometry {
    static func bedRect(in size: CGSize) -> CGRect {
        let aspect = ScanBed.widthMM / ScanBed.heightMM
        var w = size.width * 0.88
        var h = w / aspect
        if h > size.height * 0.88 {
            h = size.height * 0.88
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    static func mmToView(_ region: ScanRegion, bed: CGRect) -> CGRect {
        let sx = bed.width / ScanBed.widthMM
        let sy = bed.height / ScanBed.heightMM
        return CGRect(
            x: bed.minX + region.xMM * sx,
            y: bed.minY + region.yMM * sy,
            width: region.widthMM * sx,
            height: region.heightMM * sy
        )
    }

    static func viewToMM(_ point: CGPoint, bed: CGRect) -> (x: Double, y: Double) {
        let sx = ScanBed.widthMM / bed.width
        let sy = ScanBed.heightMM / bed.height
        return (Double(point.x - bed.minX) * sx, Double(point.y - bed.minY) * sy)
    }

    static func region(fromView rect: CGRect, bed: CGRect) -> ScanRegion {
        let p0 = viewToMM(CGPoint(x: rect.minX, y: rect.minY), bed: bed)
        let p1 = viewToMM(CGPoint(x: rect.maxX, y: rect.maxY), bed: bed)
        return ScanRegion(
            xMM: max(0, min(p0.x, ScanBed.widthMM)),
            yMM: max(0, min(p0.y, ScanBed.heightMM)),
            widthMM: max(10, min(ScanBed.widthMM, p1.x) - max(0, p0.x)),
            heightMM: max(10, min(ScanBed.heightMM, p1.y) - max(0, p0.y))
        )
    }
}
