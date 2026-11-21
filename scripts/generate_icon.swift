#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

func rgba(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

func polar(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    let rad = deg * .pi / 180.0
    return CGPoint(x: cx + r * cos(rad), y: cy + r * sin(rad))
}

func renderIconPNG(size px: Int, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to 120x120 top-left SVG design space.
    let scale = CGFloat(px) / 120.0
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)

    // Squircle shell (macOS HIG proportion: 100x100 inside 120x120 canvas, rx 22.5)
    let squircleRect = CGRect(x: 10, y: 10, width: 100, height: 100)
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: 22.5, cornerHeight: 22.5, transform: nil)

    // Drop shadow underneath squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3.0 * scale), blur: 3.5 * scale, color: rgba(0x000000, alpha: 0.25))
    ctx.addPath(squirclePath)
    ctx.setFillColor(rgba(0x151615))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill inside squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(0x222423), rgba(0x151615)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 60, y: 10), end: CGPoint(x: 60, y: 110), options: [])
    ctx.restoreGState()

    // Squircle hairline border
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(rgba(0x323636))
    ctx.setLineWidth(1.2)
    ctx.strokePath()

    // 6-segment radial meter (5 teal + 1 terracotta)
    let segments: [(CGFloat, CGFloat, UInt32)] = [
        (141, 169, 0x0799A5),
        (187, 215, 0x0799A5),
        (233, 261, 0x0799A5),
        (279, 307, 0x0799A5),
        (325, 353, 0x0799A5),
        (371, 399, 0xDE5723)
    ]
    ctx.setLineCap(.round)
    ctx.setLineWidth(5.6)
    for (startDeg, endDeg, hex) in segments {
        ctx.beginPath()
        ctx.addArc(
            center: CGPoint(x: 60, y: 60),
            radius: 34,
            startAngle: startDeg * .pi / 180.0,
            endAngle: endDeg * .pi / 180.0,
            clockwise: false
        )
        ctx.setStrokeColor(rgba(hex))
        ctx.strokePath()
    }

    // Center knob outer ring
    ctx.addEllipse(in: CGRect(x: 60 - 18.5, y: 60 - 18.5, width: 37, height: 37))
    ctx.setFillColor(rgba(0x232524))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: 60 - 18.5, y: 60 - 18.5, width: 37, height: 37))
    ctx.setStrokeColor(rgba(0x2E3232))
    ctx.setLineWidth(1.3)
    ctx.strokePath()

    // Center knob inner face
    ctx.addEllipse(in: CGRect(x: 60 - 13.5, y: 60 - 13.5, width: 27, height: 27))
    ctx.setFillColor(rgba(0x1A1B1A))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: 60 - 13.5, y: 60 - 13.5, width: 27, height: 27))
    ctx.setStrokeColor(rgba(0xE2E3E2))
    ctx.setLineWidth(1.6)
    ctx.strokePath()

    // Dial needle pointing toward segment 4 (338 deg)
    let tip = polar(60, 60, 10.5, 338)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 60, y: 60))
    ctx.addLine(to: tip)
    ctx.setStrokeColor(rgba(0x0799A5))
    ctx.setLineWidth(2.4)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Center cap
    ctx.addEllipse(in: CGRect(x: 60 - 2.6, y: 60 - 2.6, width: 5.2, height: 5.2))
    ctx.setFillColor(rgba(0xE2E3E2))
    ctx.fillPath()

    // Bottom balance hairline
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 53, y: 90))
    ctx.addLine(to: CGPoint(x: 67, y: 90))
    ctx.setStrokeColor(rgba(0x2E3232))
    ctx.setLineWidth(2.0)
    ctx.setLineCap(.round)
    ctx.strokePath()

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to make CGImage"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: px, height: px)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: url)
}

let args = CommandLine.arguments
let outIcnsPath = args.count > 1 ? args[1] : "Resources/AppIcon.icns"
let outURL = URL(fileURLWithPath: outIcnsPath)
let fm = FileManager.default
try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let tmpDir = fm.temporaryDirectory.appendingPathComponent("mm-icon-\(UUID().uuidString)")
let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmpDir) }

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in entries {
    try renderIconPNG(size: size, to: iconsetDir.appendingPathComponent(name))
}

// Also save a 512px preview PNG next to iconset if requested via 3rd arg
if args.count > 2 {
    try renderIconPNG(size: 512, to: URL(fileURLWithPath: args[2]))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outURL.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    exit(proc.terminationStatus)
}
print("Generated \(outURL.path)")
