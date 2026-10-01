// Renders app/Resources/Trot-1024.png and Trot.icns: a rounded square with a
// warm gradient, the letter T and a double arrow, since translation goes both
// ways. Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// macOS icons sit on an 824 pt square inside the 1024 pt canvas, with
// corners of about 22% of the side.
let inset: CGFloat = size * 0.0977
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// A soft drop shadow under the tile, as the system draws for its own icons.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor(calibratedRed: 0.92, green: 0.35, blue: 0.3, alpha: 1).setFill()
shape.fill()
context.restoreGState()

context.saveGState()
shape.addClip()
// Warm orange at the top left to deep rose at the bottom right.
NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.3, alpha: 1), 0),
    (NSColor(calibratedRed: 0.97, green: 0.42, blue: 0.3, alpha: 1), 0.5),
    (NSColor(calibratedRed: 0.84, green: 0.2, blue: 0.4, alpha: 1), 1)
)!.draw(in: rect, angle: -58)
// Light from above: a sheen across the top, a shade along the bottom.
NSGradient(colorsAndLocations:
    (NSColor.white.withAlphaComponent(0), 0), (NSColor.white.withAlphaComponent(0.06), 0.55), (NSColor.white.withAlphaComponent(0.22), 1)
)!.draw(in: rect, angle: 90)
NSGradient(colorsAndLocations:
    (NSColor.black.withAlphaComponent(0.14), 0), (NSColor.black.withAlphaComponent(0), 0.3)
)!.draw(in: rect, angle: 90)
// A hairline at the top edge, as glass has.
let edge = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: radius, yRadius: radius)
edge.lineWidth = size * 0.006
NSColor.white.withAlphaComponent(0.25).setStroke()
edge.stroke()
context.restoreGState()

// The glyphs cast a faint shadow so they sit on the tile rather than in it.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.02, color: NSColor.black.withAlphaComponent(0.22).cgColor)

// The letter, a little above centre to leave room for the arrow.
let font = NSFont.systemFont(ofSize: size * 0.5, weight: .heavy)
let letter = NSAttributedString(string: "T", attributes: [.font: font, .foregroundColor: NSColor.white])
let letterSize = letter.size()
let letterOrigin = CGPoint(x: rect.midX - letterSize.width / 2, y: rect.midY - letterSize.height / 2 + size * 0.075)
letter.draw(at: letterOrigin)

// A double arrow under it: translation goes both ways.
context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
context.setLineWidth(size * 0.034)
context.setLineCap(.round)
context.setLineJoin(.round)
let y = rect.minY + rect.height * 0.215
let left = rect.minX + rect.width * 0.29
let right = rect.maxX - rect.width * 0.29
let head = size * 0.05
context.move(to: CGPoint(x: left, y: y)); context.addLine(to: CGPoint(x: right, y: y))
context.move(to: CGPoint(x: left + head, y: y + head)); context.addLine(to: CGPoint(x: left, y: y)); context.addLine(to: CGPoint(x: left + head, y: y - head))
context.move(to: CGPoint(x: right - head, y: y + head)); context.addLine(to: CGPoint(x: right, y: y)); context.addLine(to: CGPoint(x: right - head, y: y - head))
context.strokePath()
context.restoreGState()
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
