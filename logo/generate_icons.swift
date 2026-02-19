#!/usr/bin/swift
/// generate_icons.swift
/// Renders ma_player_logo.svg to all required Flutter platform icon sizes.
/// Run: swift generate_icons.swift
import AppKit
import Foundation

// ── Paths ──────────────────────────────────────────────────────────────────
let scriptDir  = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let projectDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let svgPath    = scriptDir + "/ma_player_logo.svg"

// ── Render helper ──────────────────────────────────────────────────────────
func renderPNG(size: Int, outPath: String) {
    guard let image = NSImage(contentsOfFile: svgPath) else {
        fputs("ERROR: cannot load \(svgPath)\n", stderr); exit(1)
    }
    image.size = NSSize(width: size, height: size)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fputs("ERROR: bitmap alloc failed\n", stderr); exit(1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("ERROR: PNG encode failed for \(outPath)\n", stderr); exit(1)
    }

    // Ensure parent directory exists
    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    do {
        try png.write(to: URL(fileURLWithPath: outPath))
        print("  ✓ \(size)x\(size) → \(outPath.replacingOccurrences(of: projectDir + "/", with: ""))")
    } catch {
        fputs("ERROR writing \(outPath): \(error)\n", stderr); exit(1)
    }
}

// For maskable icons (web): add a colored background so the icon fills the safe zone
func renderMaskablePNG(size: Int, outPath: String, bg: NSColor = NSColor(red: 0.957, green: 0.482, blue: 0.145, alpha: 1)) {
    guard let image = NSImage(contentsOfFile: svgPath) else {
        fputs("ERROR: cannot load svg\n", stderr); exit(1)
    }
    // Inset the icon to 80% to leave safe zone padding
    let padded   = Int(Double(size) * 0.80)
    let offset   = (size - padded) / 2
    image.size   = NSSize(width: padded, height: padded)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fputs("ERROR: bitmap alloc\n", stderr); exit(1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    bg.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: offset, y: offset, width: padded, height: padded),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("ERROR: PNG encode\n", stderr); exit(1)
    }
    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("  ✓ maskable \(size)x\(size) → \(outPath.replacingOccurrences(of: projectDir + "/", with: ""))")
}

// For ICO format (Windows), generate a simple 256x256 PNG wrapped as ICO
func renderICO(outPath: String) {
    // macOS doesn't natively write .ico; write a 256-px PNG first, then convert
    let tmpPNG = outPath + ".tmp256.png"
    renderPNG(size: 256, outPath: tmpPNG)

    // Build a minimal ICO file (1 image, 256x256, 32-bit)
    guard let imgData = try? Data(contentsOf: URL(fileURLWithPath: tmpPNG)) else { return }

    var ico = Data()
    // ICO header: reserved=0, type=1(icon), count=1
    func appendLE16(_ v: UInt16) { var x = v.littleEndian; ico.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
    func appendLE32(_ v: UInt32) { var x = v.littleEndian; ico.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }

    appendLE16(0); appendLE16(1); appendLE16(1) // reserved, type, count

    // ICONDIRENTRY: width=0(256), height=0(256), colors=0, reserved=0, planes=1, bitCount=32
    ico.append(0);    // width  (0 = 256)
    ico.append(0);    // height (0 = 256)
    ico.append(0);    // color count
    ico.append(0);    // reserved
    appendLE16(1);    // planes
    appendLE16(32);   // bit count
    appendLE32(UInt32(imgData.count))   // size of image data
    appendLE32(22)    // offset to image data (6 header + 16 entry = 22)
    ico.append(contentsOf: imgData)

    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? ico.write(to: URL(fileURLWithPath: outPath))
    try? FileManager.default.removeItem(atPath: tmpPNG)
    print("  ✓ ICO 256x256 → \(outPath.replacingOccurrences(of: projectDir + "/", with: ""))")
}

let p = projectDir

print("\n📱 Android mipmap icons")
renderPNG(size: 48,  outPath: p + "/android/app/src/main/res/mipmap-mdpi/ic_launcher.png")
renderPNG(size: 72,  outPath: p + "/android/app/src/main/res/mipmap-hdpi/ic_launcher.png")
renderPNG(size: 96,  outPath: p + "/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png")
renderPNG(size: 144, outPath: p + "/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png")
renderPNG(size: 192, outPath: p + "/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")

print("\n🍎 iOS AppIcon")
renderPNG(size: 20,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png")
renderPNG(size: 40,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png")
renderPNG(size: 60,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png")
renderPNG(size: 29,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png")
renderPNG(size: 58,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png")
renderPNG(size: 87,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png")
renderPNG(size: 40,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png")
renderPNG(size: 80,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png")
renderPNG(size: 120,  outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png")
renderPNG(size: 120,  outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png")
renderPNG(size: 180,  outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png")
renderPNG(size: 76,   outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png")
renderPNG(size: 152,  outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png")
renderPNG(size: 167,  outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png")
renderPNG(size: 1024, outPath: p + "/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png")

print("\n🖥  macOS AppIcon")
renderPNG(size: 16,   outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png")
renderPNG(size: 32,   outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png")
renderPNG(size: 64,   outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png")
renderPNG(size: 128,  outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png")
renderPNG(size: 256,  outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png")
renderPNG(size: 512,  outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png")
renderPNG(size: 1024, outPath: p + "/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png")

print("\n🌐 Web icons")
renderPNG(size: 192, outPath: p + "/web/icons/Icon-192.png")
renderPNG(size: 512, outPath: p + "/web/icons/Icon-512.png")
renderPNG(size: 512, outPath: p + "/web/favicon.png")
renderMaskablePNG(size: 192, outPath: p + "/web/icons/Icon-maskable-192.png")
renderMaskablePNG(size: 512, outPath: p + "/web/icons/Icon-maskable-512.png")

print("\n🪟 Windows ICO")
renderICO(outPath: p + "/windows/runner/resources/app_icon.ico")

print("\n✅ All icons generated successfully!")
