#!/usr/bin/env swift
//
// Draws Meter's app icon and writes Resources/AppIcon.icns.
//
// Committed output, reproducible input: run `swift Scripts/make-icon.swift` after changing
// the drawing. CoreGraphics only, so there is nothing to install.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let projectDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func draw(size: CGFloat, into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Rounded square inset from the edges, following the macOS icon grid.
    let inset = size * 0.06
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = size * 0.225
    let plateePath = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

    context.saveGState()
    context.addPath(plateePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.16, 0.19, 0.24, 1])!,
            CGColor(colorSpace: space, components: [0.06, 0.08, 0.11, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    // Sits a little below the geometric centre: the arc rises above the hub, so this is
    // what makes the drawing look centred rather than measure as centred.
    let center = CGPoint(x: size / 2, y: size * 0.375)
    let radius = size * 0.300

    // Gauge track: an arc open at the bottom, the same shape as the menu bar glyph.
    let start = CGFloat.pi * 0.86
    let end = CGFloat.pi * 0.14
    context.setLineCap(.round)
    context.setLineWidth(size * 0.082)
    context.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.22])!)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    context.strokePath()

    // Filled portion, stopping short of the end so the icon reads as "in use", not "full".
    context.setStrokeColor(CGColor(colorSpace: space, components: [0.98, 0.98, 0.99, 0.95])!)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: CGFloat.pi * 0.42, clockwise: true)
    context.strokePath()

    // Needle.
    let needleAngle = CGFloat.pi * 0.42
    let tip = CGPoint(
        x: center.x + cos(needleAngle) * radius * 0.82,
        y: center.y + sin(needleAngle) * radius * 0.82
    )
    context.setLineWidth(size * 0.062)
    context.setStrokeColor(CGColor(colorSpace: space, components: [0.96, 0.66, 0.25, 1])!)
    context.move(to: center)
    context.addLine(to: tip)
    context.strokePath()

    // Hub.
    context.setFillColor(CGColor(colorSpace: space, components: [0.98, 0.98, 0.99, 1])!)
    let hub = size * 0.045
    context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
}

func image(size: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(size: CGFloat(size), into: context)
    return context.makeImage()!
}

let iconsetDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "Meter-AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetDirectory) }

// (point size, scale) pairs iconutil expects.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
var rendered: [Int: CGImage] = [:]
for variant in variants {
    let pixels = variant.points * variant.scale
    let cgImage = rendered[pixels] ?? image(size: pixels)
    rendered[pixels] = cgImage

    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let url = iconsetDirectory.appending(path: "icon_\(variant.points)x\(variant.points)\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.lastPathComponent)") }
}

let output = projectDirectory.appending(path: "Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", iconsetDirectory.path, "--output", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print(output.path)
