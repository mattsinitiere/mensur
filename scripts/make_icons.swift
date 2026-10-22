// Renders the Mensur app icon masters (E2 "even dots" faceted room).
// Usage: swift scripts/make_icons.swift [output-dir]   (default: brand/icon)
//
// Writes 1024 px full-bleed PNGs (iOS applies the corner mask) plus SVG sources:
//   mensur-icon-light   RGB, no alpha (App Store rejects alpha in the main icon)
//   mensur-icon-dark    RGB, opaque dark background
//   mensur-icon-tinted  8-bit grayscale; iOS recolours it with the user's tint

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Artwork is drawn in a 100-unit square, y pointing down, scaled to `size`.
let size = 1024
let dotsPerEdge = 14
let dotRadius = 35.0 / Double(dotsPerEdge) * 0.3

struct Plane { let origin: (Double, Double); let a: (Double, Double); let b: (Double, Double); let opacity: Double }
let planes = [
    Plane(origin: (20, 64), a: (30, -18), b: (0, -30), opacity: 1.0),   // left wall
    Plane(origin: (50, 46), a: (30, 18), b: (0, -30), opacity: 0.6),    // right wall
    Plane(origin: (50, 46), a: (-30, 18), b: (30, 18), opacity: 0.3),   // floor
]

struct Theme { let name: String; let background: (Double, Double, Double); let dots: (Double, Double, Double); let gray: Bool }
let themes = [
    Theme(name: "light", background: (0x29, 0x61, 0xCC), dots: (0xFF, 0xFF, 0xFF), gray: false),
    Theme(name: "dark", background: (0x0D, 0x14, 0x24), dots: (0x6F, 0x9B, 0xEA), gray: false),
    Theme(name: "tinted", background: (0, 0, 0), dots: (0xFF, 0xFF, 0xFF), gray: true),
]

func dotCentres(_ p: Plane) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for i in 0..<dotsPerEdge {
        for j in 0..<dotsPerEdge {
            let u = (Double(i) + 0.5) / Double(dotsPerEdge), v = (Double(j) + 0.5) / Double(dotsPerEdge)
            out.append((p.origin.0 + u * p.a.0 + v * p.b.0, p.origin.1 + u * p.a.1 + v * p.b.1))
        }
    }
    return out
}

// Pre-blend each plane's colour over the background so the PNGs stay opaque.
func blend(_ t: Theme, _ opacity: Double) -> (Double, Double, Double) {
    let mix = { (bg: Double, fg: Double) in (bg + (fg - bg) * opacity) / 255 }
    return (mix(t.background.0, t.dots.0), mix(t.background.1, t.dots.1), mix(t.background.2, t.dots.2))
}

func hex(_ c: (Double, Double, Double)) -> String {
    String(format: "#%02X%02X%02X", Int(c.0), Int(c.1), Int(c.2))
}

func renderPNG(_ t: Theme, to url: URL) throws {
    let ctx: CGContext
    if t.gray {
        ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    } else {
        ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }
    let fill = { (c: (Double, Double, Double)) in
        if t.gray { ctx.setFillColor(gray: c.0, alpha: 1) } else { ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
    }
    ctx.setShouldAntialias(true)
    fill((t.background.0 / 255, t.background.1 / 255, t.background.2 / 255))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let k = Double(size) / 100
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: CGFloat(k), y: CGFloat(-k))
    for p in planes {
        fill(blend(t, p.opacity))
        for (x, y) in dotCentres(p) {
            ctx.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        }
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

func svg(_ t: Theme) -> String {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 100 100\">\n"
    s += "  <rect width=\"100\" height=\"100\" fill=\"\(hex(t.background))\"/>\n"
    for p in planes {
        s += "  <g fill=\"\(hex(t.dots))\" fill-opacity=\"\(p.opacity)\">\n"
        for (x, y) in dotCentres(p) {
            s += String(format: "    <circle cx=\"%.3f\" cy=\"%.3f\" r=\"%.3f\"/>\n", x, y, dotRadius)
        }
        s += "  </g>\n"
    }
    return s + "</svg>\n"
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "brand/icon", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for t in themes {
    let base = outDir.appendingPathComponent("mensur-icon-\(t.name)")
    try renderPNG(t, to: base.appendingPathExtension("png"))
    try svg(t).write(to: base.appendingPathExtension("svg"), atomically: true, encoding: .utf8)
    print("wrote \(base.path).{png,svg}")
}
