#!/usr/bin/swift
import AppKit
import Foundation

func renderSVG(svgPath: String, outPath: String, size: Int) {
    guard let image = NSImage(contentsOfFile: svgPath) else {
        fputs("ERROR: cannot load \(svgPath)\n", stderr); exit(1)
    }
    image.size = NSSize(width: size, height: size)

    // Create an offscreen bitmap context with alpha
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fputs("ERROR: cannot create bitmap.\n", stderr); exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)!
    NSGraphicsContext.current = ctx

    // Fill with transparent
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // Draw SVG
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero,
               operation: .sourceOver,
               fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    // Write PNG
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        fputs("ERROR: cannot encode PNG.\n", stderr); exit(1)
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: outPath))
        let kb = (try! FileManager.default.attributesOfItem(atPath: outPath)[.size] as! Int) / 1024
        print("✓ Saved \(size)×\(size) → \(outPath)  (\(kb) KB)")
    } catch {
        fputs("ERROR writing \(outPath): \(error)\n", stderr); exit(1)
    }
}

let dir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let svg = dir + "/ma_player_logo.svg"

renderSVG(svgPath: svg, outPath: dir + "/ma_player_512x512.png", size: 512)
renderSVG(svgPath: svg, outPath: dir + "/ma_player_48x48.png",   size: 48)
print("Done.")
