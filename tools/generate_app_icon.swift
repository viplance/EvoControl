import AppKit
import Foundation

private let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

private struct IconBitmap {
    let name: String
    let size: Int
}

private let bitmaps: [IconBitmap] = [
    .init(name: "icon_16x16.png", size: 16),
    .init(name: "icon_16x16@2x.png", size: 32),
    .init(name: "icon_32x32.png", size: 32),
    .init(name: "icon_32x32@2x.png", size: 64),
    .init(name: "icon_128x128.png", size: 128),
    .init(name: "icon_128x128@2x.png", size: 256),
    .init(name: "icon_256x256.png", size: 256),
    .init(name: "icon_256x256@2x.png", size: 512),
    .init(name: "icon_512x512.png", size: 512),
    .init(name: "icon_512x512@2x.png", size: 1024)
]

private func drawIcon(size: Int) -> NSImage {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let fullRect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    NSColor.clear.setFill()
    fullRect.fill()

    let scale = dimension / 1024.0
    func r(_ value: CGFloat) -> CGFloat { value * scale }
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: r(x), y: r(y), width: r(width), height: r(height))
    }

    let body = rect(64, 64, 896, 896)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: r(206), yRadius: r(206))
    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.096, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.145, blue: 0.17, alpha: 1)
    ])
    background?.draw(in: bodyPath, angle: -45)

    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    bodyPath.lineWidth = r(7)
    bodyPath.stroke()

    let glowPath = NSBezierPath(ovalIn: rect(95, 70, 760, 360))
    NSColor(calibratedRed: 0.05, green: 0.74, blue: 0.72, alpha: 0.15).setFill()
    glowPath.fill()

    let panel = NSBezierPath(roundedRect: rect(164, 150, 696, 724), xRadius: r(118), yRadius: r(118))
    NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.94, alpha: 0.08).setFill()
    panel.fill()
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    panel.lineWidth = r(4)
    panel.stroke()

    let rails: [(x: CGFloat, knobY: CGFloat, accent: NSColor)] = [
        (316, 568, NSColor(calibratedRed: 0.94, green: 0.18, blue: 0.22, alpha: 1)),
        (512, 402, NSColor(calibratedRed: 0.08, green: 0.79, blue: 0.70, alpha: 1)),
        (708, 660, NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.22, alpha: 1))
    ]

    for rail in rails {
        let railRect = rect(rail.x - 18, 270, 36, 500)
        let railPath = NSBezierPath(roundedRect: railRect, xRadius: r(18), yRadius: r(18))
        NSColor(calibratedWhite: 0, alpha: 0.42).setFill()
        railPath.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        railPath.lineWidth = r(3)
        railPath.stroke()

        let levelHeight = max(1, 770 - rail.knobY)
        let levelPath = NSBezierPath(roundedRect: rect(rail.x - 10, rail.knobY, 20, levelHeight), xRadius: r(10), yRadius: r(10))
        rail.accent.withAlphaComponent(0.78).setFill()
        levelPath.fill()

        let knobShadow = NSBezierPath(roundedRect: rect(rail.x - 76, rail.knobY - 44, 152, 88), xRadius: r(44), yRadius: r(44))
        NSColor(calibratedWhite: 0, alpha: 0.32).setFill()
        knobShadow.fill()

        let knob = NSBezierPath(roundedRect: rect(rail.x - 68, rail.knobY - 52, 136, 92), xRadius: r(46), yRadius: r(46))
        let knobGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.90, alpha: 1),
            NSColor(calibratedRed: 0.52, green: 0.58, blue: 0.61, alpha: 1)
        ])
        knobGradient?.draw(in: knob, angle: 90)
        rail.accent.withAlphaComponent(0.85).setStroke()
        knob.lineWidth = r(7)
        knob.stroke()

        let shine = NSBezierPath(roundedRect: rect(rail.x - 38, rail.knobY - 20, 76, 16), xRadius: r(8), yRadius: r(8))
        NSColor(calibratedWhite: 1, alpha: 0.32).setFill()
        shine.fill()
    }

    let bottomMeter = NSBezierPath(roundedRect: rect(258, 194, 508, 52), xRadius: r(26), yRadius: r(26))
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    bottomMeter.fill()
    for index in 0..<9 {
        let height = CGFloat([18, 28, 36, 42, 22, 34, 46, 30, 20][index])
        let color: NSColor = index < 6
            ? NSColor(calibratedRed: 0.08, green: 0.82, blue: 0.65, alpha: 0.88)
            : NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.20, alpha: 0.88)
        color.setFill()
        NSBezierPath(roundedRect: rect(294 + CGFloat(index) * 50, 207, 22, height), xRadius: r(11), yRadius: r(11)).fill()
    }

    let badge = NSBezierPath(ovalIn: rect(702, 708, 126, 126))
    NSColor(calibratedRed: 0.94, green: 0.18, blue: 0.22, alpha: 1).setFill()
    badge.fill()
    NSColor(calibratedWhite: 1, alpha: 0.25).setStroke()
    badge.lineWidth = r(5)
    badge.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: r(72), weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    NSString(string: "E").draw(in: rect(702, 728, 126, 86), withAttributes: attributes)

    return image
}

private func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try png.write(to: url)
}

for bitmap in bitmaps {
    let image = drawIcon(size: bitmap.size)
    try writePNG(image, to: outputDirectory.appendingPathComponent(bitmap.name))
}

print(outputDirectory.path)
