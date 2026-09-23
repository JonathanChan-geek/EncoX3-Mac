import AppKit

// Original vector artwork; no vendor logo or downloaded product image.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func round(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func bud(x: CGFloat, y: CGFloat, angle: CGFloat, mirrored: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: x, yBy: y)
    transform.rotate(byDegrees: angle)
    if mirrored { transform.scaleX(by: -1, yBy: 1) }
    transform.concat()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
    round(NSRect(x: -52, y: -170, width: 102, height: 245), 49, NSColor(white: 0.84, alpha: 1))
    round(NSRect(x: -99, y: 18, width: 198, height: 162), 74, .white)
    NSShadow().set()
    round(NSRect(x: -37, y: -148, width: 18, height: 156), 9, NSColor(white: 0.98, alpha: 0.9))
    round(NSRect(x: -140, y: 75, width: 81, height: 82), 37, NSColor(white: 0.88, alpha: 1))
    round(NSRect(x: -128, y: 91, width: 25, height: 49), 12, NSColor(red: 0.10, green: 0.16, blue: 0.24, alpha: 1))
    round(NSRect(x: 31, y: 78, width: 15, height: 35), 7, NSColor(red: 0.10, green: 0.16, blue: 0.24, alpha: 1))
    round(NSRect(x: -10, y: -137, width: 16, height: 8), 4, NSColor(white: 0.42, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
}
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(size) / 1024); scale.concat()
    let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(red: 0.025, green: 0.12, blue: 0.27, alpha: 1),
               ending: NSColor(red: 0.03, green: 0.60, blue: 0.86, alpha: 1))!.draw(in: shape, angle: 65)
    bud(x: 355, y: 476, angle: -17, mirrored: false)
    bud(x: 687, y: 538, angle: 17, mirrored: true)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
