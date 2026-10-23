// Rebuild with: swift IconGenerator.swift [pink|black] [icns path] [png path]
//   swift IconGenerator.swift pink Resources/AppIcon.icns Resources/AppIcon-Pink.png
//   swift IconGenerator.swift black Resources/AppIcon-Black.icns Resources/AppIcon-Black.png
// The ACdian mark: a flat tile with the A and C drawn as two round-capped strokes.
// Pink with a black mark is the bundle's default icon; black with a pink mark is the alternative.
// Geometry follows the SVG design (1024 canvas, y down); the in-app BrandMark uses the same paths.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let pink = arguments.first != "black"
let destination = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : (pink ? "Resources/AppIcon.icns" : "Resources/AppIcon-Black.icns"))
let pngDestination = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : (pink ? "Resources/AppIcon-Pink.png" : "Resources/AppIcon-Black.png"))
let manager = FileManager.default
let scratch = manager.temporaryDirectory.appendingPathComponent("acdian-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: scratch) }

let black = CGColor(srgbRed: 0x14 / 255.0, green: 0x12 / 255.0, blue: 0x17 / 255.0, alpha: 1)
let rose = CGColor(srgbRed: 0xD9 / 255.0, green: 0x3B / 255.0, blue: 0x86 / 255.0, alpha: 1)
let (tileColor, markColor) = pink ? (rose, black) : (black, rose)

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
// Flip once so every coordinate below is the SVG's own.
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)

let tile = CGPath(roundedRect: CGRect(x: 55, y: 55, width: 914, height: 914), cornerWidth: 211, cornerHeight: 211, transform: nil)
context.saveGState()
// Shadow offsets ignore the flip (they are in device space), so -7 still falls downward.
context.setShadow(offset: CGSize(width: 0, height: -7), blur: 24, color: CGColor(gray: 0, alpha: 0.30))
context.addPath(tile)
context.setFillColor(tileColor)
context.fillPath()
context.restoreGState()

let a = CGMutablePath()
a.move(to: CGPoint(x: 196, y: 742))
a.addLine(to: CGPoint(x: 328, y: 318))
a.addCurve(to: CGPoint(x: 374, y: 318), control1: CGPoint(x: 340, y: 278), control2: CGPoint(x: 362, y: 278))
a.addLine(to: CGPoint(x: 455, y: 596))
a.addCurve(to: CGPoint(x: 672, y: 790), control1: CGPoint(x: 490, y: 720), control2: CGPoint(x: 570, y: 790))
a.addCurve(to: CGPoint(x: 856, y: 678), control1: CGPoint(x: 762, y: 790), control2: CGPoint(x: 826, y: 744))
let c = CGMutablePath()
c.move(to: CGPoint(x: 856, y: 352))
c.addCurve(to: CGPoint(x: 672, y: 246), control1: CGPoint(x: 826, y: 290), control2: CGPoint(x: 762, y: 246))
c.addCurve(to: CGPoint(x: 540, y: 296), control1: CGPoint(x: 618, y: 246), control2: CGPoint(x: 574, y: 264))

// translate(512 512) scale(.88) translate(-512 -512) translate(22 -4) skewX(-5), innermost first.
let markTransform = CGAffineTransform(a: 1, b: 0, c: tan(-5 * .pi / 180), d: 1, tx: 0, ty: 0)
    .concatenating(CGAffineTransform(translationX: 22, y: -4))
    .concatenating(CGAffineTransform(translationX: -512, y: -512))
    .concatenating(CGAffineTransform(scaleX: 0.88, y: 0.88))
    .concatenating(CGAffineTransform(translationX: 512, y: 512))
context.saveGState()
context.concatenate(markTransform)
context.addPath(a)
context.addPath(c)
context.setStrokeColor(markColor)
context.setLineWidth(112)
context.setLineCap(.round)
context.setLineJoin(.round)
context.strokePath()
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
let source = scratch.appendingPathComponent("AppIcon-1024.png")
try png.write(to: source)
try manager.createDirectory(at: pngDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: pngDestination)

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
print("Created \(destination.path) and \(pngDestination.path)")
