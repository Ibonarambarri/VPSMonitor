#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconSpec {
    let filename: String
    let size: Int
    let compactGlyph: Bool
}

private let specs = [
    IconSpec(filename: "vpsmonitor-icon-v3-1024.png", size: 1024, compactGlyph: false),
    IconSpec(filename: "vpsmonitor-icon-v3-512.png", size: 512, compactGlyph: false),
    IconSpec(filename: "vpsmonitor-icon-v3-maskable-512.png", size: 512, compactGlyph: true),
    IconSpec(filename: "vpsmonitor-icon-v3-192.png", size: 192, compactGlyph: false),
    IconSpec(filename: "vpsmonitor-apple-touch-icon-v3-180.png", size: 180, compactGlyph: false),
    IconSpec(filename: "vpsmonitor-favicon-v3-32.png", size: 32, compactGlyph: false),
]

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func drawIcon(size: Int, compactGlyph: Bool) -> Data? {
    let side = CGFloat(size)
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    color(255, 255, 255).setFill()
    NSBezierPath(rect: canvas).fill()

    let horizontalInset = compactGlyph ? side * 0.285 : side * 0.235
    let rackWidth = side - horizontalInset * 2
    let unitHeight = side * 0.13
    let gap = side * 0.055
    let totalHeight = unitHeight * 3 + gap * 2
    let startY = (side - totalHeight) / 2
    let radius = max(2, side * 0.03)
    let strokeWidth = max(1.35, side * 0.029)

    for index in 0..<3 {
        let y = startY + CGFloat(index) * (unitHeight + gap)
        let inset = strokeWidth / 2
        let rect = NSRect(
            x: horizontalInset + inset,
            y: y + inset,
            width: rackWidth - strokeWidth,
            height: unitHeight - strokeWidth
        )
        let unit = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        unit.lineWidth = strokeWidth
        color(17, 17, 17).setStroke()
        unit.stroke()

        let indicatorSize = max(1.8, side * 0.027)
        let indicatorRect = NSRect(
            x: rect.minX + side * 0.078,
            y: rect.midY - indicatorSize / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        color(17, 17, 17).setFill()
        NSBezierPath(ovalIn: indicatorRect).fill()

        let ventHeight = max(1.35, side * 0.022)
        let ventRect = NSRect(
            x: rect.minX + side * 0.18,
            y: rect.midY - ventHeight / 2,
            width: rect.width - side * 0.245,
            height: ventHeight
        )
        NSBezierPath(roundedRect: ventRect, xRadius: ventHeight / 2, yRadius: ventHeight / 2).fill()
    }

    return representation.representation(using: .png, properties: [.compressionFactor: 0.95])
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "public/icons", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in specs {
    guard let data = drawIcon(size: spec.size, compactGlyph: spec.compactGlyph) else {
        fputs("No se pudo generar \(spec.filename)\n", stderr)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(spec.filename), options: .atomic)
}
