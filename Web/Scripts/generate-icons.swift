#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconSpec {
    let filename: String
    let size: Int
    let compactGlyph: Bool
}

private let specs = [
    IconSpec(filename: "icon-1024.png", size: 1024, compactGlyph: false),
    IconSpec(filename: "icon-512.png", size: 512, compactGlyph: false),
    IconSpec(filename: "icon-maskable-512.png", size: 512, compactGlyph: true),
    IconSpec(filename: "icon-192.png", size: 192, compactGlyph: false),
    IconSpec(filename: "apple-touch-icon-180.png", size: 180, compactGlyph: false),
    IconSpec(filename: "favicon-32.png", size: 32, compactGlyph: false),
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
    let gradient = NSGradient(colors: [color(10, 132, 255), color(0, 86, 214)])!
    gradient.draw(in: canvas, angle: -54)

    let glow = NSBezierPath(ovalIn: NSRect(x: side * 0.06, y: side * 0.48, width: side * 0.9, height: side * 0.74))
    color(124, 202, 255, alpha: 0.18).setFill()
    glow.fill()

    let horizontalInset = compactGlyph ? side * 0.235 : side * 0.205
    let rackWidth = side - horizontalInset * 2
    let unitHeight = side * 0.158
    let gap = side * 0.055
    let totalHeight = unitHeight * 3 + gap * 2
    let startY = (side - totalHeight) / 2
    let radius = max(2, side * 0.038)

    let shadow = NSShadow()
    shadow.shadowColor = color(0, 34, 92, alpha: 0.22)
    shadow.shadowBlurRadius = side * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()

    for index in 0..<3 {
        let y = startY + CGFloat(index) * (unitHeight + gap)
        let rect = NSRect(x: horizontalInset, y: y, width: rackWidth, height: unitHeight)
        let unit = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color(255, 255, 255, alpha: 0.97).setFill()
        unit.fill()

        NSShadow().set()

        let indicatorSize = max(2.2, side * 0.035)
        let indicatorRect = NSRect(
            x: rect.minX + side * 0.072,
            y: rect.midY - indicatorSize / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        color(10, 132, 255).setFill()
        NSBezierPath(ovalIn: indicatorRect).fill()

        let ventHeight = max(1.2, side * 0.012)
        let ventWidth = side * 0.075
        let ventGap = side * 0.027
        for vent in 0..<3 {
            let ventRect = NSRect(
                x: rect.maxX - side * 0.09 - ventWidth - CGFloat(vent) * (ventWidth + ventGap),
                y: rect.midY - ventHeight / 2,
                width: ventWidth,
                height: ventHeight
            )
            color(0, 70, 165, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: ventRect, xRadius: ventHeight / 2, yRadius: ventHeight / 2).fill()
        }

        shadow.set()
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
