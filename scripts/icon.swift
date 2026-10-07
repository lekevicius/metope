import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = NSRect(x: 58, y: 58, width: 908, height: 908)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    NSGradient(colors: [NSColor(calibratedRed: 0.12, green: 0.52, blue: 0.76, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.26, blue: 0.47, alpha: 1)])!.draw(in: shape, angle: -70)
    NSColor.white.withAlphaComponent(0.16).setStroke(); shape.lineWidth = 2; shape.stroke()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
    let phone = NSBezierPath(roundedRect: NSRect(x: 335, y: 239, width: 354, height: 572), xRadius: 70, yRadius: 70)
    NSColor.white.withAlphaComponent(0.97).setFill(); phone.fill()
    NSShadow().set()
    let screen = NSBezierPath(roundedRect: NSRect(x: 357, y: 260, width: 310, height: 528), xRadius: 51, yRadius: 51)
    NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.61, alpha: 1).setFill(); screen.fill()
    let island = NSBezierPath(roundedRect: NSRect(x: 460, y: 750, width: 104, height: 15), xRadius: 8, yRadius: 8); NSColor.white.withAlphaComponent(0.8).setFill(); island.fill()
    let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 454, y: 605)); arrow.line(to: NSPoint(x: 454, y: 426)); arrow.move(to: NSPoint(x: 399, y: 480)); arrow.line(to: NSPoint(x: 454, y: 425)); arrow.line(to: NSPoint(x: 509, y: 480))
    arrow.move(to: NSPoint(x: 572, y: 425)); arrow.line(to: NSPoint(x: 572, y: 604)); arrow.move(to: NSPoint(x: 517, y: 550)); arrow.line(to: NSPoint(x: 572, y: 605)); arrow.line(to: NSPoint(x: 627, y: 550))
    NSColor.white.setStroke(); arrow.lineWidth = 22; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    let cable = NSBezierPath(); cable.move(to: NSPoint(x: 512, y: 241)); cable.line(to: NSPoint(x: 512, y: 143)); cable.lineWidth = 21; cable.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.9).setStroke(); cable.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try data.write(to: URL(fileURLWithPath: output + "/icon_\(size)x\(size).png")) }
    if [32, 64, 256, 512, 1024].contains(size) { try data.write(to: URL(fileURLWithPath: output + "/icon_\(size/2)x\(size/2)@2x.png")) }
}
