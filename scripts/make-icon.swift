// Draws the XSpace app icon and writes Support/AppIcon.icns.
//
//   swift scripts/make-icon.swift            -> Support/AppIcon.icns
//   swift scripts/make-icon.swift out.png    -> also a 1024 px preview
//
// The artwork follows the macOS icon grid (an 824 pt rounded square with continuous corners on
// a 1024 pt canvas): three browser panes side by side, each in the color of a profile.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

/// Rounded rectangle with continuous ("squircle") corners, like Apple's icon shape.
func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // One corner as (along the incoming edge, along the outgoing edge) offsets, in units of r.
    let start: (CGFloat, CGFloat) = (1.52866483, 0)
    let curves: [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))] = [
        ((0.63149399, 0.07491100), (1.08849323, 0), (0.86840701, 0)),
        ((0.07491100, 0.63149399), (0.37282869, 0.16905803), (0.16905803, 0.37282869)),
        ((0, 1.52866483), (0, 0.86840701), (0, 1.08849323)),
    ]
    // Corners clockwise (y up): corner point, incoming direction, outgoing direction.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (index, (corner, a, b)) in corners.enumerated() {
        func point(_ k: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: corner.x - k.0 * r * a.dx + k.1 * r * b.dx, y: corner.y - k.0 * r * a.dy + k.1 * r * b.dy)
        }
        if index == 0 { path.move(to: point(start)) } else { path.addLine(to: point(start)) }
        for (end, c1, c2) in curves {
            path.addCurve(to: point(end), control1: point(c1), control2: point(c2))
        }
    }
    path.closeSubpath()
    return path
}

/// Draws the icon at `pixels` × `pixels`. Small sizes leave out details that would only blur.
func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    let detailed = pixels >= 64
    context.scaleBy(x: scale, y: scale)

    // Background tile with a soft shadow.
    let tile = continuousRect(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185)
    context.saveGState()
    if detailed {
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    }
    context.addPath(tile)
    context.setFillColor(color(0x1B2030))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(colorsSpace: sRGB, colors: [color(0x323B55), color(0x141826)] as CFArray,
                                locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // Three panes, each framed in a profile color (blue, green, orange).
    let profileColors: [UInt32] = [0x0A84FF, 0x30D158, 0xFF9F0A]
    let gap: CGFloat = detailed ? 34 : 44
    let paneWidth = (608 - gap * 2) / 3
    let bottom: CGFloat = 236, top: CGFloat = 788
    let toolbarHeight: CGFloat = detailed ? 88 : 150
    for (index, hex) in profileColors.enumerated() {
        let pane = CGRect(x: 208 + CGFloat(index) * (paneWidth + gap), y: bottom, width: paneWidth, height: top - bottom)
        let shape = CGPath(roundedRect: pane, cornerWidth: 30, cornerHeight: 30, transform: nil)

        context.saveGState()
        if detailed {
            context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.4))
        }
        context.addPath(shape)
        context.setFillColor(color(0xF5F7FB))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(color(hex))
        context.fill(CGRect(x: pane.minX, y: pane.maxY - toolbarHeight, width: pane.width, height: toolbarHeight))
        if detailed {
            // Address bar in the pane toolbar, and a few lines of page content.
            let field = CGRect(x: pane.minX + 24, y: pane.maxY - toolbarHeight / 2 - 13, width: pane.width - 48, height: 26)
            context.addPath(CGPath(roundedRect: field, cornerWidth: 13, cornerHeight: 13, transform: nil))
            context.setFillColor(color(0xFFFFFF, 0.55))
            context.fillPath()
            for (line, fraction) in [0.78, 0.92, 0.6, 0.85, 0.7, 0.5].enumerated() {
                let y = pane.maxY - toolbarHeight - 58 - CGFloat(line) * 54
                let bar = CGRect(x: pane.minX + 28, y: y, width: (pane.width - 56) * fraction, height: 22)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 11, cornerHeight: 11, transform: nil))
            }
            context.setFillColor(color(0xD3D9E4))
            context.fillPath()
        }
        context.restoreGState()

        // Profile-colored frame, like the border of a pane in the app.
        let lineWidth: CGFloat = detailed ? 8 : 14
        let frame = pane.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 30 - lineWidth / 2, cornerHeight: 30 - lineWidth / 2,
                               transform: nil))
        context.setStrokeColor(color(hex))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("XSpace-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try writePNG(drawIcon(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(drawIcon(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Support/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try writePNG(drawIcon(pixels: 1024), to: preview)
    print("Wrote \(preview.path)")
}
