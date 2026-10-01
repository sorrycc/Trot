// Renders app/Resources/Trot-1024.png and Trot.icns: a rounded square with a
// gradient and the letter T over a double arrow. Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// macOS icons leave a margin inside the canvas.
let inset: CGFloat = size * 0.1
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
path.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.49, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.36, alpha: 1),
])!
gradient.draw(in: rect, angle: -60)

// A soft highlight across the top.
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.2)])!
highlight.draw(in: rect, angle: 90)

// The letter.
let font = NSFont.systemFont(ofSize: size * 0.52, weight: .heavy)
let letter = NSAttributedString(string: "T", attributes: [.font: font, .foregroundColor: NSColor.white])
let letterSize = letter.size()
letter.draw(at: CGPoint(x: rect.midX - letterSize.width / 2, y: rect.midY - letterSize.height / 2 + size * 0.06))

// A double arrow under it: translation goes both ways.
context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
context.setLineWidth(size * 0.028)
context.setLineCap(.round)
context.setLineJoin(.round)
let y = rect.minY + rect.height * 0.21
let left = rect.minX + rect.width * 0.3
let right = rect.maxX - rect.width * 0.3
let head = size * 0.045
context.move(to: CGPoint(x: left, y: y)); context.addLine(to: CGPoint(x: right, y: y))
context.move(to: CGPoint(x: left + head, y: y + head)); context.addLine(to: CGPoint(x: left, y: y)); context.addLine(to: CGPoint(x: left + head, y: y - head))
context.move(to: CGPoint(x: right - head, y: y + head)); context.addLine(to: CGPoint(x: right, y: y)); context.addLine(to: CGPoint(x: right - head, y: y - head))
context.strokePath()
image.unlockFocus()

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("app/Resources")
let png = resources.appendingPathComponent("Trot-1024.png")
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: png)

// iconutil wants an iconset folder with every size.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Trot.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let scaled = NSImage(size: NSSize(width: pixels, height: pixels))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    scaled.unlockFocus()
    let scaledRep = NSBitmapImageRep(data: scaled.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! scaledRep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Trot.icns").path]
try! process.run()
process.waitUntilExit()
print("wrote \(png.path) and Trot.icns (status \(process.terminationStatus))")
