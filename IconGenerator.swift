// Rebuild with: swift IconGenerator.swift [Resources/AppIcon.icns]
// This icon is drawn entirely from native macOS shapes and a rounded system glyph.
import AppKit
import CoreText

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let manager = FileManager.default
let scratch = manager.temporaryDirectory.appendingPathComponent("acdian-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: scratch) }

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tile = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 211, yRadius: 211)
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
tileShadow.shadowBlurRadius = 24
tileShadow.shadowOffset = NSSize(width: 0, height: -7)
tileShadow.set()
NSColor(calibratedRed: 0.075, green: 0.067, blue: 0.086, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.125, blue: 0.155, alpha: 1), ending: NSColor(calibratedRed: 0.055, green: 0.052, blue: 0.067, alpha: 1))!.draw(in: tile, angle: -90)
NSColor.white.withAlphaComponent(0.10).setStroke()
tile.lineWidth = 2
tile.stroke()

let rounded = NSFont.systemFont(ofSize: 800, weight: .semibold).fontDescriptor.withDesign(.rounded)!
let font = NSFont(descriptor: rounded, size: 800)!
let ctFont = CTFontCreateWithName(font.fontName as CFString, 800, nil)
var character: UniChar = 97
var glyph: CGGlyph = 0
precondition(CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1))
let glyphPath = CTFontCreatePathForGlyph(ctFont, glyph, nil)!
// The same leaning, rounded lowercase a used by the in-app BrandMark.
var lean = CGAffineTransform(a: 1, b: 0, c: 0.11, d: 1, tx: 0, ty: 0)
let leaningPath = glyphPath.copy(using: &lean)!
let leaningBox = leaningPath.boundingBoxOfPath
let scale = 548 / leaningBox.height
var placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
    tx: 512 - leaningBox.midX * scale - 10,
    ty: 514 - leaningBox.midY * scale)
let mark = leaningPath.copy(using: &placement)!

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: NSColor(srgbRed: 217.0 / 255, green: 59.0 / 255, blue: 134.0 / 255, alpha: 0.17).cgColor)
context.addPath(mark)
context.setFillColor(NSColor(srgbRed: 217.0 / 255, green: 59.0 / 255, blue: 134.0 / 255, alpha: 1).cgColor)
context.fillPath()
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let source = scratch.appendingPathComponent("AppIcon-1024.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: source)

@discardableResult func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 1 ? "" : "@2x"
        let pixels = points * multiplier
        let path = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        let conversion = try run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", source.path, "--out", path.path])
        precondition(conversion == 0)
    }
}
try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
let result = try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", destination.path])
if result != 0 {
    // iconutil can fail when its IconServices helper is unavailable in a sandbox.
    // Modern ICNS also accepts these lossless PNG image chunks directly.
    let chunks: [(String, String)] = [
        ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
    ]
    func bigEndian(_ value: Int) -> Data {
        var number = UInt32(value).bigEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    var contents = Data()
    for (kind, filename) in chunks {
        let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
        contents.append(Data(kind.utf8))
        contents.append(bigEndian(png.count + 8))
        contents.append(png)
    }
    var file = Data("icns".utf8)
    file.append(bigEndian(contents.count + 8))
    file.append(contents)
    try file.write(to: destination, options: .atomic)
}
print("Created \(destination.path)")
