import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("could not create icon bitmap")
}
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create icon context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let full = NSRect(x: 0, y: 0, width: size, height: size)
NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
NSBezierPath(roundedRect: full.insetBy(dx: 20, dy: 20), xRadius: 210, yRadius: 210).fill()

NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
let border = NSBezierPath(roundedRect: full.insetBy(dx: 20, dy: 20), xRadius: 210, yRadius: 210)
border.lineWidth = 6
border.stroke()

// The island pill merged with the top edge, exactly like the collapsed state.
let pillRect = NSRect(x: 232, y: size - 92 - 152, width: 560, height: 152)
let pill = NSBezierPath(roundedRect: pillRect, xRadius: 76, yRadius: 76)
NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
pill.fill()
NSColor(calibratedRed: 0.353, green: 0.561, blue: 1.0, alpha: 0.65).setStroke()
pill.lineWidth = 5
pill.stroke()

// Authored four-point spark, no external glyph.
let center = NSPoint(x: 512, y: 830)
let long: CGFloat = 62
let short: CGFloat = 14
let spark = NSBezierPath()
spark.move(to: NSPoint(x: center.x, y: center.y + long))
spark.line(to: NSPoint(x: center.x + short, y: center.y + short))
spark.line(to: NSPoint(x: center.x + long, y: center.y))
spark.line(to: NSPoint(x: center.x + short, y: center.y - short))
spark.line(to: NSPoint(x: center.x, y: center.y - long))
spark.line(to: NSPoint(x: center.x - short, y: center.y - short))
spark.line(to: NSPoint(x: center.x - long, y: center.y))
spark.line(to: NSPoint(x: center.x - short, y: center.y + short))
spark.close()
NSColor(calibratedRed: 0.353, green: 0.561, blue: 1.0, alpha: 1).setFill()
spark.fill()

let line = NSBezierPath(roundedRect: NSRect(x: 402, y: 300, width: 220, height: 10), xRadius: 5, yRadius: 5)
NSColor(calibratedRed: 0.353, green: 0.561, blue: 1.0, alpha: 0.35).setFill()
line.fill()

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) \(png.count) bytes")
