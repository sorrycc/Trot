// Cuts app/Resources/Trot-1024.png and Trot.icns out of Trot-artwork.png, the
// rendered arcade-cabinet tile on a white background. The white around the
// tile goes transparent, the tile is fitted to the 824 pt square macOS icons
// sit on, and its corners are clipped to the system's rounded shape.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("app/Resources")
guard let artwork = NSImage(contentsOf: resources.appendingPathComponent("Trot-artwork.png")),
      let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("app/Resources/Trot-artwork.png is missing or not an image")
}

// Read the artwork into an RGBA buffer, top row first.
let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let buffer = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
buffer.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

// Flood the near-white background in from the edges and make it transparent,
// so white inside the artwork (the horse's blaze, highlights) is left alone.
func isBackground(_ i: Int) -> Bool { pixels[i * 4] > 225 && pixels[i * 4 + 1] > 225 && pixels[i * 4 + 2] > 225 }
var visited = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
while let i = stack.popLast() {
    if visited[i] || !isBackground(i) { continue }
    visited[i] = true
    pixels[i * 4] = 0; pixels[i * 4 + 1] = 0; pixels[i * 4 + 2] = 0; pixels[i * 4 + 3] = 0
    let x = i % width, y = i / width
    if x > 0 { stack.append(i - 1) }
    if x < width - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - width) }
    if y < height - 1 { stack.append(i + width) }
}

// The tile's bounds: only clearly coloured or dark pixels count, which skips
// the soft shadow and the faint glow the render painted around the tile.
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        guard pixels[i + 3] > 0 else { continue }
        let hi = max(pixels[i], pixels[i + 1], pixels[i + 2]), lo = min(pixels[i], pixels[i + 1], pixels[i + 2])
        if hi - lo < 80 && hi > 100 { continue }
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
precondition(maxX >= minX && maxY >= minY, "no tile found in the artwork")
let tileRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let tile = NSImage(cgImage: buffer.makeImage()!.cropping(to: tileRect)!, size: tileRect.size)

// Everything is drawn into explicit 8-bit RGBA bitmaps: drawing through
// NSImage.lockFocus gives 16-bit PNGs at the screen's scale, and macOS 26
// shows a 16-bit icns shrunk inside the legacy glass frame.
func canvas(_ pixels: Int, _ body: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    body()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// macOS icons sit on an 824 pt square inside the 1024 pt canvas, with
// corners of about 22% of the side. The tile is drawn a hair larger than the
// square so its anti-aliased edge falls outside the clip.
let size: CGFloat = 1024
let inset = size * 0.0977
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let icon = canvas(Int(size)) {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    let target = rect.insetBy(dx: -size * 0.006, dy: -size * 0.006)
    let scale = max(target.width / tileRect.width, target.height / tileRect.height)
    let drawn = CGSize(width: tileRect.width * scale, height: tileRect.height * scale)
    tile.draw(in: CGRect(x: target.midX - drawn.width / 2, y: target.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
              from: .zero, operation: .sourceOver, fraction: 1)
}

let png = resources.appendingPathComponent("Trot-1024.png")
try! icon.representation(using: .png, properties: [:])!.write(to: png)

// iconutil wants an iconset folder with every size.
let image = NSImage(size: NSSize(width: size, height: size))
image.addRepresentation(icon)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Trot.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let scaled = canvas(pixels) {
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! scaled.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Trot.icns").path]
try! process.run()
process.waitUntilExit()
print("tile \(Int(tileRect.width))x\(Int(tileRect.height)) at \(minX),\(minY); wrote \(png.path) and Trot.icns (status \(process.terminationStatus))")
